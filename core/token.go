package main

import (
	"context"
	"crypto/ed25519"
	"encoding/base32"
	"encoding/base64"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/log"
)

type dnsAuthSettings struct {
	privKey  ed25519.PrivateKey
	window   int64
	suffixes []string
}

const dnsAuthWindowSeconds = 300

const dnsAuthCacheTTL = 300 * time.Second

type dnsAuthIPCacheEntry struct {
	ips    []netip.Addr
	expire time.Time
}

var (
	dnsAuthLock    sync.RWMutex
	dnsAuthCurrent *dnsAuthSettings
	dnsAuthIPCache sync.Map
)

func setDNSAuth(s *dnsAuthSettings) {
	clearDNSAuthCache()
	dnsAuthLock.Lock()
	dnsAuthCurrent = s
	dnsAuthLock.Unlock()
}

func clearDNSAuthCache() {
	dnsAuthIPCache.Range(func(key, _ any) bool {
		dnsAuthIPCache.Delete(key)
		return true
	})
}

func dnsAuthCacheKey(host, kind string) string {
	return kind + "\x00" + strings.ToLower(strings.TrimSuffix(host, "."))
}

func getDNSAuthIPCache(host, kind string) ([]netip.Addr, bool) {
	key := dnsAuthCacheKey(host, kind)
	value, ok := dnsAuthIPCache.Load(key)
	if !ok {
		return nil, false
	}
	entry, ok := value.(dnsAuthIPCacheEntry)
	if !ok || time.Now().After(entry.expire) {
		dnsAuthIPCache.Delete(key)
		return nil, false
	}
	ips := append([]netip.Addr(nil), entry.ips...)
	return ips, true
}

func putDNSAuthIPCache(host, kind string, ips []netip.Addr) {
	if len(ips) == 0 {
		return
	}
	dnsAuthIPCache.Store(dnsAuthCacheKey(host, kind), dnsAuthIPCacheEntry{
		ips:    append([]netip.Addr(nil), ips...),
		expire: time.Now().Add(dnsAuthCacheTTL),
	})
}

func currentDNSAuth() *dnsAuthSettings {
	dnsAuthLock.RLock()
	defer dnsAuthLock.RUnlock()
	return dnsAuthCurrent
}

func dnsAuthSuffixes() []string {
	if GlobalDNSAuthDomains == "" {
		return nil
	}
	seen := make(map[string]struct{})
	suffixes := make([]string, 0)
	for _, d := range strings.Split(GlobalDNSAuthDomains, ",") {
		s := strings.ToLower(strings.TrimSpace(d))
		s = strings.TrimPrefix(s, "*.")
		s = strings.TrimSuffix(s, ".")
		if s == "" || strings.Contains(s, "*") {
			continue
		}
		if _, ok := seen[s]; ok {
			continue
		}
		seen[s] = struct{}{}
		suffixes = append(suffixes, s)
	}
	return suffixes
}

func applyDNSAuth() {
	suffixes := dnsAuthSuffixes()
	if len(suffixes) == 0 {
		setDNSAuth(nil)
		return
	}
	if GlobalDNSAuthPrivateKey != "" {
		seed, err := base64.StdEncoding.DecodeString(strings.TrimSpace(GlobalDNSAuthPrivateKey))
		if err == nil && len(seed) == ed25519.SeedSize {
			setDNSAuth(&dnsAuthSettings{privKey: ed25519.NewKeyFromSeed(seed), window: dnsAuthWindowSeconds, suffixes: suffixes})
			log.Infoln("[DNS-Auth] enabled (ed25519) for %d managed suffix(es)", len(suffixes))
			return
		}
		log.Warnln("[DNS-Auth] invalid private key")
	}
	setDNSAuth(nil)
}

var dnsAuthEncoding = base32.StdEncoding.WithPadding(base32.NoPadding)

func dnsAuthMessage(basename string, window int64) []byte {
	b := make([]byte, 0, len(basename)+1+20)
	b = append(b, basename...)
	b = append(b, '|')
	b = strconv.AppendInt(b, window, 10)
	return b
}

func (s *dnsAuthSettings) matchSuffix(name string) (string, bool) {
	for _, suf := range s.suffixes {
		if name == suf || strings.HasSuffix(name, "."+suf) {
			return suf, true
		}
	}
	return "", false
}

func tokenizeHost(host string) string {
	s := currentDNSAuth()
	if s == nil || host == "" {
		return host
	}
	name := strings.ToLower(strings.TrimSuffix(host, "."))
	if _, ok := s.matchSuffix(name); !ok {
		return host
	}
	if s.privKey == nil {
		return host
	}
	window := time.Now().Unix() / s.window
	sig := ed25519.Sign(s.privKey, dnsAuthMessage(name, window))
	half := ed25519.SignatureSize / 2
	p1 := strings.ToLower(dnsAuthEncoding.EncodeToString(sig[:half]))
	p2 := strings.ToLower(dnsAuthEncoding.EncodeToString(sig[half:]))
	return p1 + "." + p2 + "." + name
}

func matchManagedSuffix(host string) bool {
	_, ok := maskManagedDomain(host)
	return ok
}

func maskManagedDomain(host string) (string, bool) {
	s := currentDNSAuth()
	if s == nil || host == "" {
		return host, false
	}
	name := strings.ToLower(strings.TrimSuffix(host, "."))
	port := ""
	if h, p, err := net.SplitHostPort(name); err == nil {
		name, port = h, p
	}
	suf, ok := s.matchSuffix(name)
	if !ok {
		return host, false
	}
	masked := "***." + suf
	if port != "" {
		masked += ":" + port
	}
	return masked, true
}

type tokenInjectResolver struct {
	resolver.Resolver
}

// managedLookup wraps a resolver lookup with the DNS-Auth token rewrite. For
// managed suffixes it also serves/populates the fixed-TTL IP cache and marks
// resolved IPs as cloud nodes; other hosts pass straight through.
func (t *tokenInjectResolver) managedLookup(ctx context.Context, host, kind string, lookup func(context.Context, string) ([]netip.Addr, error)) ([]netip.Addr, error) {
	if !matchManagedSuffix(host) {
		return lookup(ctx, tokenizeHost(host))
	}
	if ips, ok := getDNSAuthIPCache(host, kind); ok {
		markCloudIPs(ips)
		return ips, nil
	}
	ips, err := lookup(ctx, tokenizeHost(host))
	if err == nil {
		markCloudIPs(ips)
		putDNSAuthIPCache(host, kind, ips)
	}
	return ips, err
}

func (t *tokenInjectResolver) LookupIP(ctx context.Context, host string) ([]netip.Addr, error) {
	return t.managedLookup(ctx, host, "ip", t.Resolver.LookupIP)
}

func (t *tokenInjectResolver) LookupIPv4(ctx context.Context, host string) ([]netip.Addr, error) {
	return t.managedLookup(ctx, host, "ipv4", t.Resolver.LookupIPv4)
}

func (t *tokenInjectResolver) LookupIPv6(ctx context.Context, host string) ([]netip.Addr, error) {
	return t.managedLookup(ctx, host, "ipv6", t.Resolver.LookupIPv6)
}

func (t *tokenInjectResolver) ResolveECH(ctx context.Context, host string) ([]byte, error) {
	return t.Resolver.ResolveECH(ctx, tokenizeHost(host))
}

func (t *tokenInjectResolver) ClearCache() {
	clearDNSAuthCache()
	t.Resolver.ClearCache()
}

func (t *tokenInjectResolver) ResetConnection() {
	clearDNSAuthCache()
	t.Resolver.ResetConnection()
}

func installDNSAuthResolver() {
	if currentDNSAuth() == nil {
		return
	}
	inner := resolver.ProxyServerHostResolver
	if inner == nil {
		return
	}
	if _, ok := inner.(*tokenInjectResolver); ok {
		return
	}
	resolver.ProxyServerHostResolver = &tokenInjectResolver{Resolver: inner}
}
