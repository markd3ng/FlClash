package main

import (
	"errors"
	"testing"
)

type testSelectable struct {
	selected string
	valid    map[string]bool
	fallback string
}

func (selector *testSelectable) Set(name string) error {
	if !selector.valid[name] {
		return errors.New("proxy not exist")
	}
	selector.selected = name
	return nil
}

func (selector *testSelectable) ForceSet(name string) {
	selector.selected = name
}

func (selector *testSelectable) Now() string {
	if selector.valid[selector.selected] {
		return selector.selected
	}
	return selector.fallback
}

func TestRestoreSelectorSelection(t *testing.T) {
	tests := []struct {
		name     string
		selected string
		want     string
	}{
		{name: "keeps existing selection", selected: "second", want: "second"},
		{name: "falls back when selection is missing", selected: "removed", want: "first"},
		{name: "falls back when selection is empty", selected: "", want: "first"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			selector := &testSelectable{
				valid:    map[string]bool{"first": true, "second": true},
				fallback: "first",
			}
			restoreSelectorSelection(selector, test.selected)
			if selector.selected != test.want {
				t.Fatalf("selected = %q, want %q", selector.selected, test.want)
			}
		})
	}
}

func TestNormalizeSelectorSelection(t *testing.T) {
	selector := &testSelectable{
		selected: "removed",
		valid:    map[string]bool{"first": true},
		fallback: "first",
	}
	normalizeSelectorSelection(selector)
	if selector.selected != "first" {
		t.Fatalf("selected = %q, want %q", selector.selected, "first")
	}
}

func TestHandleUpdateConfigBeforeSetup(t *testing.T) {
	previousConfig := currentConfig
	currentConfig = nil
	t.Cleanup(func() {
		currentConfig = previousConfig
	})

	if message := handleUpdateConfig([]byte(`{}`)); message != "" {
		t.Fatalf("message = %q, want empty", message)
	}
}
