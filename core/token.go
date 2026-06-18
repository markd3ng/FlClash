package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base32"
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
	secret   string
	window   int64
	suffixes []string
}

const dnsAuthWindowSeconds = 300

var (
	dnsAuthLock    sync.RWMutex
	dnsAuthCurrent *dnsAuthSettings
)

func setDNSAuth(s *dnsAuthSettings) {
	dnsAuthLock.Lock()
	dnsAuthCurrent = s
	dnsAuthLock.Unlock()
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
	if GlobalDNSAuthSecret == "" {
		setDNSAuth(nil)
		return
	}
	suffixes := dnsAuthSuffixes()
	if len(suffixes) == 0 {
		setDNSAuth(nil)
		return
	}
	setDNSAuth(&dnsAuthSettings{secret: GlobalDNSAuthSecret, window: dnsAuthWindowSeconds, suffixes: suffixes})
	log.Infoln("[DNS-Auth] enabled for %d managed suffix(es)", len(suffixes))
}

var dnsAuthEncoding = base32.StdEncoding.WithPadding(base32.NoPadding)

const dnsAuthTokenBytes = 10

func computeDNSAuthToken(secret, basename string, window int64) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(basename))
	mac.Write([]byte{'|'})
	mac.Write([]byte(strconv.FormatInt(window, 10)))
	sum := mac.Sum(nil)
	return strings.ToLower(dnsAuthEncoding.EncodeToString(sum[:dnsAuthTokenBytes]))
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
	window := time.Now().Unix() / s.window
	token := computeDNSAuthToken(s.secret, name, window)
	return token + "." + name
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

func (t *tokenInjectResolver) LookupIP(ctx context.Context, host string) ([]netip.Addr, error) {
	ips, err := t.Resolver.LookupIP(ctx, tokenizeHost(host))
	if err == nil && matchManagedSuffix(host) {
		markCloudIPs(ips)
	}
	return ips, err
}

func (t *tokenInjectResolver) LookupIPv4(ctx context.Context, host string) ([]netip.Addr, error) {
	ips, err := t.Resolver.LookupIPv4(ctx, tokenizeHost(host))
	if err == nil && matchManagedSuffix(host) {
		markCloudIPs(ips)
	}
	return ips, err
}

func (t *tokenInjectResolver) LookupIPv6(ctx context.Context, host string) ([]netip.Addr, error) {
	ips, err := t.Resolver.LookupIPv6(ctx, tokenizeHost(host))
	if err == nil && matchManagedSuffix(host) {
		markCloudIPs(ips)
	}
	return ips, err
}

func (t *tokenInjectResolver) ResolveECH(ctx context.Context, host string) ([]byte, error) {
	return t.Resolver.ResolveECH(ctx, tokenizeHost(host))
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
