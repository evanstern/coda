package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func runProvider(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: coda-core provider <auth|status|fallback-models>")
	}
	switch args[0] {
	case "auth":
		return runProviderAuth(args[1:])
	case "status":
		return runProviderStatus(args[1:])
	case "fallback-models":
		return runProviderFallbackModels()
	default:
		return fmt.Errorf("unknown provider subcommand: %s", args[0])
	}
}

func runProviderFallbackModels() error {
	models := fallbackModels()
	data, err := json.MarshalIndent(models, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(data))
	return nil
}

func runProviderAuth(args []string) error {
	fs := flag.NewFlagSet("provider-auth", flag.ExitOnError)
	baseURL := fs.String("base-url", "", "CLIProxyAPI base URL")
	configPath := fs.String("config", "", "OpenCode config file path")
	apiKey := fs.String("api-key", "", "Optional API key (prefer CODA_API_KEY env var)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *baseURL == "" || *configPath == "" {
		return fmt.Errorf("--base-url and --config are required")
	}
	if *apiKey == "" {
		*apiKey = os.Getenv("CODA_API_KEY")
	}

	modelsJSON, err := discoverModels(*baseURL, *apiKey)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Warning: could not discover models from %s/models\n", *baseURL)
		fmt.Fprintln(os.Stderr, "Writing fallback CLIProxyAPI provider config instead.")
		modelsJSON = fallbackModels()
	}

	if err := mergeProviderConfig(*configPath, *baseURL, *apiKey, modelsJSON); err != nil {
		return err
	}

	fmt.Printf("Updated OpenCode config: %s\n", *configPath)
	fmt.Println("Provider mode: cliproxyapi")
	fmt.Printf("Base URL: %s\n", *baseURL)
	return nil
}

func runProviderStatus(args []string) error {
	fs := flag.NewFlagSet("provider-status", flag.ExitOnError)
	mode := fs.String("mode", "claude-auth", "Provider mode")
	configPath := fs.String("config", "", "OpenCode config file path")
	baseURL := fs.String("base-url", "", "CLIProxyAPI base URL")
	healthURL := fs.String("health-url", "", "Optional health URL")
	apiKey := fs.String("api-key", "", "Optional API key (prefer CODA_API_KEY env var)")
	hasOpencode := fs.String("has-opencode", "false", "Whether opencode is installed")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *apiKey == "" {
		*apiKey = os.Getenv("CODA_API_KEY")
	}

	fmt.Printf("Provider mode: %s\n", *mode)
	fmt.Printf("OpenCode config: %s\n", *configPath)

	if *hasOpencode == "true" {
		fmt.Println("opencode: found")
	} else {
		fmt.Println("opencode: missing")
	}

	providerBlockPresent := "unknown"
	providerAuthPresent := "unknown"

	if *configPath != "" {
		data, err := os.ReadFile(*configPath)
		if err == nil {
			var config map[string]interface{}
			if json.Unmarshal(data, &config) == nil {
				providerBlockPresent, providerAuthPresent = checkProviderBlock(config)
			} else {
				fmt.Printf("cliproxyapi provider block: config is not a valid JSON object (%s)\n", *configPath)
			}
		} else if os.IsNotExist(err) {
			fmt.Println("cliproxyapi provider block: config file not found (run: coda auth)")
		}
	}

	if *mode == "cliproxyapi" {
		normURL := strings.TrimRight(*baseURL, "/")
		if normURL == "" || (!strings.HasPrefix(normURL, "http://") && !strings.HasPrefix(normURL, "https://")) {
			fmt.Printf("Base URL: invalid (%s)\n", *baseURL)
			return fmt.Errorf("invalid base URL")
		}

		modelsURL := normURL + "/models"

		if providerBlockPresent == "yes" {
			if *apiKey != "" && providerAuthPresent == "no" {
				fmt.Println("cliproxyapi provider block: present, but missing proxy auth (re-run: coda auth)")
			} else {
				fmt.Println("cliproxyapi provider block: present (configuration ready; runtime not proven)")
			}
			if providerAuthPresent == "yes" {
				fmt.Println("Managed proxy auth: present in provider block")
			} else {
				fmt.Println("Managed proxy auth: absent from provider block")
			}
		} else if providerBlockPresent == "no" {
			fmt.Println("cliproxyapi provider block: absent (run: coda auth)")
		}

		if *apiKey != "" {
			fmt.Println("Proxy API key env: set in CLIPROXYAPI_API_KEY")
		} else {
			fmt.Println("Proxy API key env: not set (optional)")
		}

		printURLStatus("Base URL", normURL)
		if *healthURL != "" {
			normHealth := strings.TrimRight(*healthURL, "/")
			if strings.HasPrefix(normHealth, "http://") || strings.HasPrefix(normHealth, "https://") {
				printURLStatus("Health URL", normHealth)
			} else {
				fmt.Printf("Health URL: invalid (%s)\n", *healthURL)
			}
		} else {
			fmt.Println("Health URL: skipped (CLIPROXYAPI_HEALTH_URL not set)")
		}

		printModelsStatus(modelsURL, *apiKey)
		fmt.Println("Readiness note: config and HTTP probes are not end-to-end runtime proof.")
	}

	return nil
}

func checkProviderBlock(config map[string]interface{}) (blockPresent, authPresent string) {
	blockPresent = "no"
	authPresent = "no"

	provider, ok := config["provider"].(map[string]interface{})
	if !ok {
		return
	}

	clip, ok := provider["cliproxyapi"].(map[string]interface{})
	if !ok {
		return
	}
	blockPresent = "yes"

	opts, ok := clip["options"].(map[string]interface{})
	if !ok {
		return
	}
	if key, ok := opts["apiKey"].(string); ok && key != "" {
		authPresent = "yes"
	}
	return
}

func printURLStatus(label, url string) {
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		fmt.Printf("%s: unreachable (%s)\n", label, url)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		fmt.Printf("%s: reachable (%s, HTTP %d)\n", label, url, resp.StatusCode)
	} else {
		fmt.Printf("%s: reachable with non-2xx response (%s, HTTP %d)\n", label, url, resp.StatusCode)
	}
}

func printModelsStatus(modelsURL, apiKey string) {
	client := &http.Client{Timeout: 5 * time.Second}
	req, err := http.NewRequest("GET", modelsURL, nil)
	if err != nil {
		fmt.Printf("Models endpoint: unreachable (%s)\n", modelsURL)
		return
	}
	if apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+apiKey)
	}

	resp, err := client.Do(req)
	if err != nil {
		fmt.Printf("Models endpoint: unreachable (%s)\n", modelsURL)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode == 401 || resp.StatusCode == 403 {
		if apiKey != "" {
			fmt.Printf("Models endpoint: unauthorized (%s, HTTP %d; configured proxy API key was rejected)\n", modelsURL, resp.StatusCode)
		} else {
			fmt.Printf("Models endpoint: unauthorized (%s, HTTP %d; set CLIPROXYAPI_API_KEY if your proxy requires auth)\n", modelsURL, resp.StatusCode)
		}
		return
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		fmt.Printf("Models endpoint: reachable with non-2xx response (%s, HTTP %d)\n", modelsURL, resp.StatusCode)
		return
	}

	body, _ := io.ReadAll(resp.Body)
	var data struct {
		Data []interface{} `json:"data"`
	}
	if json.Unmarshal(body, &data) == nil && len(data.Data) > 0 {
		fmt.Printf("Models endpoint: reachable (%s, HTTP %d, %d models)\n", modelsURL, resp.StatusCode, len(data.Data))
	} else {
		fmt.Printf("Models endpoint: reachable but returned no usable models (%s, HTTP %d)\n", modelsURL, resp.StatusCode)
	}
}

func discoverModels(baseURL, apiKey string) (map[string]interface{}, error) {
	client := &http.Client{Timeout: 5 * time.Second}
	req, err := http.NewRequest("GET", baseURL+"/models", nil)
	if err != nil {
		return nil, err
	}
	if apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+apiKey)
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	var raw struct {
		Data []json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, err
	}

	result := make(map[string]interface{})
	for _, item := range raw.Data {
		var obj map[string]interface{}
		var str string

		if json.Unmarshal(item, &obj) == nil {
			if id, ok := obj["id"].(string); ok && id != "" {
				name := id
				if n, ok := obj["name"].(string); ok && n != "" {
					name = n
				}
				result[id] = map[string]string{"name": name}
			}
		} else if json.Unmarshal(item, &str) == nil && str != "" {
			result[str] = map[string]string{"name": str}
		}
	}

	if len(result) == 0 {
		return nil, fmt.Errorf("no models found")
	}
	return result, nil
}

func fallbackModels() map[string]interface{} {
	return map[string]interface{}{
		"gpt-4o":                     map[string]string{"name": "gpt-4o"},
		"gpt-4.1":                    map[string]string{"name": "gpt-4.1"},
		"claude-opus-4-6":            map[string]string{"name": "claude-opus-4-6"},
		"claude-haiku-4-5-20251001":  map[string]string{"name": "claude-haiku-4-5-20251001"},
		"claude-sonnet-4-5-20250929": map[string]string{"name": "claude-sonnet-4-5-20250929"},
	}
}

func mergeProviderConfig(configPath, baseURL, apiKey string, models map[string]interface{}) error {
	configDir := filepath.Dir(configPath)
	if err := os.MkdirAll(configDir, 0755); err != nil {
		return fmt.Errorf("creating config directory: %w", err)
	}

	existing := make(map[string]interface{})
	if data, err := os.ReadFile(configPath); err == nil {
		if json.Unmarshal(data, &existing) != nil {
			return fmt.Errorf("existing OpenCode config is not valid JSON object: %s", configPath)
		}
	}

	provider, ok := existing["provider"].(map[string]interface{})
	if !ok {
		provider = make(map[string]interface{})
	}

	opts := map[string]interface{}{
		"baseURL": baseURL,
	}
	if apiKey != "" {
		opts["apiKey"] = apiKey
	}

	provider["cliproxyapi"] = map[string]interface{}{
		"npm":     "@ai-sdk/openai-compatible",
		"name":    "CLIProxyAPI",
		"options": opts,
		"models":  models,
	}
	existing["provider"] = provider

	out, err := json.MarshalIndent(existing, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling config: %w", err)
	}

	tmpFile := configPath + ".tmp"
	if err := os.WriteFile(tmpFile, out, 0644); err != nil {
		return fmt.Errorf("writing config: %w", err)
	}
	if err := os.Rename(tmpFile, configPath); err != nil {
		os.Remove(tmpFile)
		return fmt.Errorf("replacing config: %w", err)
	}

	return nil
}
