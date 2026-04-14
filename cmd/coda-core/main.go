package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	var err error
	switch os.Args[1] {
	case "layout":
		err = runLayout(os.Args[2:])
	case "provider":
		err = runProvider(os.Args[2:])
	case "watch":
		err = runWatch(os.Args[2:])
	case "help", "--help", "-h":
		printUsage()
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n", os.Args[1])
		printUsage()
		os.Exit(1)
	}

	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Fprintln(os.Stderr, `coda-core — internal helper for the coda shell functions

Usage: coda-core <command> [args...]

Commands:
  layout snapshot    Capture current tmux layout as a reusable layout script
  provider auth      Configure CLIProxyAPI provider in OpenCode config
  provider status    Show provider diagnostics
  watch              Monitor OpenCode sessions and notify on attention needed`)
}
