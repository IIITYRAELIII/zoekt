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
	"fmt"
	"log"
	"math"
	"os"
	"unsafe"

	"golang.org/x/sys/windows"
)

type mmapedIndexFile struct {
	name string
	size uint32
	data []byte
	addr uintptr
}

func (f *mmapedIndexFile) Read(off, sz uint32) ([]byte, error) {
	if off > off+sz || off+sz > uint32(len(f.data)) {
		return nil, fmt.Errorf("out of bounds: %d, len %d, name %s", off+sz, len(f.data), f.name)
	}
	return f.data[off : off+sz], nil
}

func (f *mmapedIndexFile) Name() string {
	return f.name
}

func (f *mmapedIndexFile) Size() (uint32, error) {
	return f.size, nil
}

func (f *mmapedIndexFile) Close() {
	if f.addr == 0 {
		return
	}
	if err := windows.UnmapViewOfFile(f.addr); err != nil {
		log.Printf("WARN failed to UnmapViewOfFile %s: %v", f.name, err)
	}
	f.addr = 0
	f.data = nil
}

// NewIndexFile returns a memory-mapped index file and takes ownership of f.
func NewIndexFile(f *os.File) (IndexFile, error) {
	defer f.Close()

	name := f.Name()
	info, err := f.Stat()
	if err != nil {
		return nil, fmt.Errorf("stat index file %s: %w", name, err)
	}

	size := info.Size()
	if size >= math.MaxUint32 {
		return nil, fmt.Errorf("file %s too large: %d", name, size)
	}
	if size == 0 {
		return nil, fmt.Errorf("cannot map empty file %s", name)
	}
	if uint64(size) > uint64(^uint(0)>>1) {
		return nil, fmt.Errorf("file %s cannot be addressed by this architecture: %d", name, size)
	}

	mapping, err := windows.CreateFileMapping(
		windows.Handle(f.Fd()),
		nil,
		windows.PAGE_READONLY,
		0,
		0,
		nil,
	)
	if err != nil {
		return nil, fmt.Errorf("CreateFileMapping %s: %w", name, err)
	}
	defer windows.CloseHandle(mapping)

	addr, err := windows.MapViewOfFile(mapping, windows.FILE_MAP_READ, 0, 0, 0)
	if err != nil {
		return nil, fmt.Errorf("MapViewOfFile %s: %w", name, err)
	}

	return &mmapedIndexFile{
		name: name,
		size: uint32(size),
		data: unsafe.Slice((*byte)(unsafe.Pointer(addr)), int(size)),
		addr: addr,
	}, nil
}
