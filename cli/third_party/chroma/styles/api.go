package styles

import (
	"embed"
	"io/fs"
	"sort"
	"strings"
	"sync"

	"github.com/alecthomas/chroma/v2"
)

//go:embed *.xml
var embedded embed.FS

// Registry of Styles. It holds the styles built so far, not the ones the
// package ships: those are parsed on first use, since almost every caller
// wants one style by name and parsing all of them costs a terminal-free
// renderer more than it will ever use.
var Registry = map[string]*chroma.Style{}

// files maps a style's file name, which is its name in the registry, to the
// embedded file it is parsed from.
var files = func() map[string]string {
	entries, err := fs.ReadDir(embedded, ".")
	if err != nil {
		panic(err)
	}
	files := map[string]string{}
	for _, entry := range entries {
		if name, ok := strings.CutSuffix(entry.Name(), ".xml"); ok {
			files[name] = entry.Name()
		}
	}
	return files
}()

var loading sync.Mutex

// lookup returns the named style, parsing the embedded style of that name the
// first time it is asked for.
func lookup(name string) (*chroma.Style, bool) {
	name = strings.ToLower(name)
	if style, ok := Registry[name]; ok {
		return style, true
	}
	file, ok := files[name]
	if !ok {
		return nil, false
	}
	loading.Lock()
	defer loading.Unlock()
	if style, ok := Registry[name]; ok {
		return style, true
	}
	r, err := embedded.Open(file)
	if err != nil {
		panic(err)
	}
	style, err := chroma.NewXMLStyle(r)
	_ = r.Close()
	if err != nil {
		panic(err)
	}
	Registry[strings.ToLower(style.Name)] = style
	return style, true
}

// Fallback style. Reassign to change the default fallback style.
var Fallback = func() *chroma.Style {
	style, _ := lookup("swapoff")
	return style
}()

// Register a chroma.Style.
func Register(style *chroma.Style) *chroma.Style {
	Registry[strings.ToLower(style.Name)] = style
	return style
}

// Names of all available styles. It parses every style the package ships.
func Names() []string {
	for name := range files {
		_, _ = lookup(name)
	}
	out := []string{}
	for name := range Registry {
		out = append(out, name)
	}
	sort.Strings(out)
	return out
}

// Get named style, or Fallback.
func Get(name string) *chroma.Style {
	if style, ok := lookup(name); ok {
		return style
	}
	return Fallback
}

// GetForMode returns the named style if it already matches mode, otherwise its
// registered counterpart if one exists and matches mode. If neither matches,
// the originally-requested style is returned (or Fallback if the name is
// unknown), so callers always get something usable.
func GetForMode(name string, mode chroma.Mode) *chroma.Style {
	style := Get(name)
	if style.Mode() == mode {
		return style
	}
	if style.Counterpart == "" {
		return style
	}
	counterpart, ok := lookup(style.Counterpart)
	if !ok || counterpart.Mode() != mode {
		return style
	}
	return counterpart
}

// RegisterPair links two styles as light/dark counterparts of each other.
//
// Both styles are also registered if they are not already present.
func RegisterPair(a, b *chroma.Style) {
	Register(a)
	Register(b)
	a.Counterpart = strings.ToLower(b.Name)
	b.Counterpart = strings.ToLower(a.Name)
}
