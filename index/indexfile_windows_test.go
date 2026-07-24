// Copyright 2026 The Zoekt Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//go:build windows

package index

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestWindowsMmapedIndexFile(t *testing.T) {
	content := []byte("Процедура Тест()\nДинамическийСписок = Истина;\nКонецПроцедуры\n")
	path := filepath.Join(t.TempDir(), "модуль.bsl")
	if err := os.WriteFile(path, content, 0o600); err != nil {
		t.Fatal(err)
	}

	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	indexFile, err := NewIndexFile(file)
	if err != nil {
		t.Fatal(err)
	}
	defer indexFile.Close()

	size, err := indexFile.Size()
	if err != nil {
		t.Fatal(err)
	}
	if size != uint32(len(content)) {
		t.Fatalf("Size() = %d, want %d", size, len(content))
	}
	if indexFile.Name() != path {
		t.Fatalf("Name() = %q, want %q", indexFile.Name(), path)
	}

	got, err := indexFile.Read(0, size)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, content) {
		t.Fatalf("Read() = %q, want %q", got, content)
	}

	if _, err := indexFile.Read(size, 1); err == nil {
		t.Fatal("out-of-bounds Read() unexpectedly succeeded")
	}
}

func TestWindowsMmapedIndexFileRejectsEmptyFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "empty.zoekt")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := NewIndexFile(file); err == nil {
		t.Fatal("NewIndexFile() unexpectedly mapped an empty file")
	}
}
