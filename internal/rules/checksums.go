package rules

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
)

// ChecksumFile records the checksum of every file intellisense vendored, so an update can tell a file it
// wrote from one a person edited.
const ChecksumFile = Dir + "/.checksums.json"

// Checksums maps a repo-relative path to the sha256 of the content intellisense last wrote there.
type Checksums map[string]string

// LoadChecksums reads the record; a missing record is empty.
func LoadChecksums(root string) (Checksums, error) {
	data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(ChecksumFile)))
	if errors.Is(err, os.ErrNotExist) {
		return Checksums{}, nil
	}
	if err != nil {
		return nil, err
	}
	sums := Checksums{}
	if err := json.Unmarshal(data, &sums); err != nil {
		return nil, errors.New(ChecksumFile + " is not valid JSON; delete it and run `intellisense rules update --force`")
	}
	return sums, nil
}

// Save writes the record, sorted, so it diffs cleanly.
func (c Checksums) Save(root string) error {
	keys := make([]string, 0, len(c))
	for k := range c {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b bytes.Buffer
	b.WriteString("{\n")
	for i, k := range keys {
		kj, _ := json.Marshal(k)
		vj, _ := json.Marshal(c[k])
		b.Write(kj)
		b.WriteString(": ")
		b.Write(vj)
		if i < len(keys)-1 {
			b.WriteString(",")
		}
		b.WriteString("\n")
	}
	b.WriteString("}\n")
	path := filepath.Join(root, filepath.FromSlash(ChecksumFile))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, b.Bytes(), 0o644)
}

func sum(data []byte) string {
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])
}

// State is how a vendored file relates to what intellisense last wrote.
type State int

const (
	Absent   State = iota // no file
	Unedited              // the file is exactly what intellisense wrote
	Edited                // someone changed it after intellisense wrote it
	Unknown               // a file intellisense has no record of
)

// State reports a file's state.
func (c Checksums) State(root, rel string) State {
	data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil {
		return Absent
	}
	recorded, ok := c[rel]
	switch {
	case !ok:
		return Unknown
	case recorded == sum(data):
		return Unedited
	}
	return Edited
}

// write puts data at rel according to mode. It returns whether it wrote, and whether it kept an edited file.
func (c Checksums) write(root, rel string, data []byte, mode Mode) (wrote, kept bool, err error) {
	path := filepath.Join(root, filepath.FromSlash(rel))
	current, readErr := os.ReadFile(path)
	exists := readErr == nil
	if exists && bytes.Equal(current, data) {
		c[rel] = sum(data)
		return false, false, nil
	}
	if exists {
		switch st := c.State(root, rel); {
		case mode == Force:
		case mode == Update && st == Unedited:
		case mode == Missing:
			if st == Unknown || st == Unedited {
				return false, false, nil
			}
			return false, true, nil
		default:
			return false, true, nil
		}
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return false, false, err
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return false, false, err
	}
	c[rel] = sum(data)
	return true, false, nil
}

// removeUnedited deletes rel when it is an unedited copy intellisense wrote, and forgets it.
func (c Checksums) removeUnedited(root, rel string) (bool, error) {
	if c.State(root, rel) != Unedited {
		return false, nil
	}
	if err := os.Remove(filepath.Join(root, filepath.FromSlash(rel))); err != nil {
		return false, err
	}
	delete(c, rel)
	return true, nil
}
