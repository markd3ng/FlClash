package main

import (
	"net/netip"
	"testing"

	"github.com/metacubex/mihomo/constant"
)

func TestMaskMetadataRemovesManagedDestinationIP(t *testing.T) {
	setMaskedAddrs(true)
	t.Cleanup(func() { setMaskedAddrs(false) })
	markCloudIP("192.0.2.10")
	metadata := &constant.Metadata{
		Host:      "192.0.2.10",
		SniffHost: "192.0.2.10:443",
		RemoteDst: "192.0.2.10:443",
		DstIP:     netip.MustParseAddr("192.0.2.10"),
		DstGeoIP:  []string{"TEST"},
		DstIPASN:  "AS64500",
	}

	maskMetadata(metadata)

	if metadata.DstIP.IsValid() || metadata.DstGeoIP != nil || metadata.DstIPASN != "" {
		t.Fatalf("managed destination metadata was not cleared: %+v", metadata)
	}
	for name, value := range map[string]string{
		"host":              metadata.Host,
		"sniffHost":         metadata.SniffHost,
		"remoteDestination": metadata.RemoteDst,
	} {
		if value != "***.***.***.***" && value != "***.***.***.***:443" {
			t.Fatalf("%s was not masked: %q", name, value)
		}
	}
}
