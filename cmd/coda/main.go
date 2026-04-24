// Package main is the entrypoint for the coda CLI.
package main

import (
	"flag"
	"fmt"
	"os"
)

// Version is the coda CLI version. Set via -ldflags at build time.
var Version = "dev"

func main() {
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "usage: coda <command> [flags]\n\n")
		fmt.Fprintf(os.Stderr, "commands:\n")
		fmt.Fprintf(os.Stderr, "  version   print the coda version\n")
	}
	flag.Parse()

	args := flag.Args()
	if len(args) == 0 {
		flag.Usage()
		os.Exit(2)
	}

	switch args[0] {
	case "version":
		fmt.Println(Version)
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n", args[0])
		flag.Usage()
		os.Exit(2)
	}
}
