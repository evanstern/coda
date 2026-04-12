package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestMergeProviderConfig_NewFile(t *testing.T) {
	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "opencode.json")

	models := map[string]interface{}{
		"gpt-4o": map[string]string{"name": "gpt-4o"},
	}

	err := mergeProviderConfig(configPath, "http://localhost:8317/v1", "test-key", models)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	data, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatalf("could not read config: %v", err)
	}

	var config map[string]interface{}
	if err := json.Unmarshal(data, &config); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}

	provider := config["provider"].(map[string]interface{})
	clip := provider["cliproxyapi"].(map[string]interface{})

	if clip["npm"] != "@ai-sdk/openai-compatible" {
		t.Errorf("npm = %v, want @ai-sdk/openai-compatible", clip["npm"])
	}
	if clip["name"] != "CLIProxyAPI" {
		t.Errorf("name = %v, want CLIProxyAPI", clip["name"])
	}

	opts := clip["options"].(map[string]interface{})
	if opts["baseURL"] != "http://localhost:8317/v1" {
		t.Errorf("baseURL = %v", opts["baseURL"])
	}
	if opts["apiKey"] != "test-key" {
		t.Errorf("apiKey = %v", opts["apiKey"])
	}
}

func TestMergeProviderConfig_PreservesExistingKeys(t *testing.T) {
	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "opencode.json")

	existing := `{"theme": "dark", "provider": {"other": {"key": "val"}}}`
	os.WriteFile(configPath, []byte(existing), 0644)

	models := map[string]interface{}{"m1": map[string]string{"name": "m1"}}
	err := mergeProviderConfig(configPath, "http://localhost/v1", "", models)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	data, _ := os.ReadFile(configPath)
	var config map[string]interface{}
	json.Unmarshal(data, &config)

	if config["theme"] != "dark" {
		t.Error("existing top-level key 'theme' was lost")
	}

	provider := config["provider"].(map[string]interface{})
	if provider["other"] == nil {
		t.Error("existing provider 'other' was lost")
	}
	if provider["cliproxyapi"] == nil {
		t.Error("cliproxyapi was not added")
	}
}

func TestMergeProviderConfig_NoApiKey(t *testing.T) {
	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "opencode.json")

	models := map[string]interface{}{"m1": map[string]string{"name": "m1"}}
	err := mergeProviderConfig(configPath, "http://localhost/v1", "", models)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	data, _ := os.ReadFile(configPath)
	var config map[string]interface{}
	json.Unmarshal(data, &config)

	provider := config["provider"].(map[string]interface{})
	clip := provider["cliproxyapi"].(map[string]interface{})
	opts := clip["options"].(map[string]interface{})

	if _, exists := opts["apiKey"]; exists {
		t.Error("apiKey should not be present when empty")
	}
}

func TestMergeProviderConfig_InvalidExisting(t *testing.T) {
	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "opencode.json")
	os.WriteFile(configPath, []byte("not json"), 0644)

	models := map[string]interface{}{}
	err := mergeProviderConfig(configPath, "http://localhost/v1", "", models)
	if err == nil {
		t.Error("expected error for invalid JSON")
	}
}

func TestCheckProviderBlock(t *testing.T) {
	tests := []struct {
		name      string
		config    map[string]interface{}
		wantBlock string
		wantAuth  string
	}{
		{
			"no provider key",
			map[string]interface{}{},
			"no", "no",
		},
		{
			"provider but no cliproxyapi",
			map[string]interface{}{"provider": map[string]interface{}{"other": true}},
			"no", "no",
		},
		{
			"cliproxyapi present without auth",
			map[string]interface{}{"provider": map[string]interface{}{
				"cliproxyapi": map[string]interface{}{"options": map[string]interface{}{"baseURL": "http://x"}},
			}},
			"yes", "no",
		},
		{
			"cliproxyapi present with auth",
			map[string]interface{}{"provider": map[string]interface{}{
				"cliproxyapi": map[string]interface{}{"options": map[string]interface{}{"apiKey": "sk-test"}},
			}},
			"yes", "yes",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			block, auth := checkProviderBlock(tc.config)
			if block != tc.wantBlock {
				t.Errorf("block = %q, want %q", block, tc.wantBlock)
			}
			if auth != tc.wantAuth {
				t.Errorf("auth = %q, want %q", auth, tc.wantAuth)
			}
		})
	}
}

func TestDiscoverModels(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/models" {
			w.WriteHeader(404)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"data": [{"id": "gpt-4o", "name": "GPT-4o"}, {"id": "claude-3", "name": "Claude 3"}]}`))
	}))
	defer server.Close()

	models, err := discoverModels(server.URL, "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(models) != 2 {
		t.Fatalf("expected 2 models, got %d", len(models))
	}
	if models["gpt-4o"] == nil {
		t.Error("missing gpt-4o")
	}
	if models["claude-3"] == nil {
		t.Error("missing claude-3")
	}
}

func TestDiscoverModels_WithApiKey(t *testing.T) {
	var receivedAuth string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		receivedAuth = r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"data": [{"id": "m1"}]}`))
	}))
	defer server.Close()

	_, err := discoverModels(server.URL, "sk-test-key")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if receivedAuth != "Bearer sk-test-key" {
		t.Errorf("auth header = %q, want 'Bearer sk-test-key'", receivedAuth)
	}
}

func TestDiscoverModels_StringModels(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"data": ["gpt-4o", "claude-3"]}`))
	}))
	defer server.Close()

	models, err := discoverModels(server.URL, "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(models) != 2 {
		t.Fatalf("expected 2 models, got %d", len(models))
	}
}

func TestDiscoverModels_EmptyResponse(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"data": []}`))
	}))
	defer server.Close()

	_, err := discoverModels(server.URL, "")
	if err == nil {
		t.Error("expected error for empty models")
	}
}

func TestDiscoverModels_ServerError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(500)
	}))
	defer server.Close()

	_, err := discoverModels(server.URL, "")
	if err == nil {
		t.Error("expected error for 500 response")
	}
}

func TestFallbackModels(t *testing.T) {
	models := fallbackModels()
	if len(models) == 0 {
		t.Error("fallback models should not be empty")
	}
	if models["gpt-4o"] == nil {
		t.Error("missing gpt-4o in fallback")
	}
}
