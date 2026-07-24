//go:build windows

package main

import "testing"

func TestDiskUsagePathWindows(t *testing.T) {
	path, err := diskUsagePath(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if path == "" {
		t.Fatal("diskUsagePath() returned an empty path")
	}

	usage, err := diskUsage(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if usage.Total == 0 {
		t.Fatal("diskUsage() returned zero total space")
	}
}
