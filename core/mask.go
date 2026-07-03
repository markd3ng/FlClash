package main

import (
	"net"
	"net/netip"
	"sync"
	"sync/atomic"

	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

var (
	isOixCloud atomic.Bool
	cloudIPs   sync.Map
)

func init() {
	statistic.MetadataProcessor = maskMetadata
	constant.MetadataStringMasker = maskAddr
	route.DNSQueryObfuscated = matchManagedSuffix
}

func setMaskedAddrs(isOix bool) {
	isOixCloud.Store(isOix)
	cloudIPs.Clear()
}

func markCloudIP(ip string) {
	if ip != "" {
		cloudIPs.Store(ip, true)
	}
}

func markCloudIPs(ips []netip.Addr) {
	for _, ip := range ips {
		markCloudIP(ip.String())
	}
}

func isCloudIP(host string) bool {
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	if _, err := netip.ParseAddr(host); err != nil {
		return false
	}
	_, ok := cloudIPs.Load(host)
	return ok
}

func maskMetadata(m *constant.Metadata) {
	if m == nil || !isOixCloud.Load() {
		return
	}
	m.RemoteDst = maskAddr(m.RemoteDst)
	m.Host = maskAddr(m.Host)
	m.SniffHost = maskAddr(m.SniffHost)
}

func maskAddr(host string) string {
	if host == "" {
		return host
	}
	if masked, ok := maskManagedDomain(host); ok {
		return masked
	}
	if isCloudIP(host) {
		if _, port, err := net.SplitHostPort(host); err == nil {
			return "***.***.***.***:" + port
		}
		return "***.***.***.***"
	}
	return host
}
