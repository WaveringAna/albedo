// Package lexers ships the lexers chroma builds from the XML files in
// embedded/, and builds them when they are asked for.
//
// Upstream keeps every lexer, config and analyser, for as long as the program
// runs, which a terminal that renders a handful of languages pays for
// nothing. Here an embedded lexer is reduced to what it can be found by — its
// name, aliases and file patterns — and the lexer itself, its rules and its
// compiled analysers, is built the first time something asks for it.
package lexers

import (
	"embed"
	"encoding/xml"
	"fmt"
	"io/fs"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/alecthomas/chroma/v2"
)

//go:embed embedded
var embedded embed.FS

// GlobalLexerRegistry is the global LexerRegistry of Lexers. It holds the
// lexers built so far; Lookup is how a rule that names another lexer reaches
// one that is not built yet.
var GlobalLexerRegistry = chroma.NewLexerRegistry()

func init() { // nolint:gochecknoinits
	GlobalLexerRegistry.Lookup = Get
}

// entry is what an embedded lexer's config says about it. Its rules stay in
// the file until the lexer is built.
type entry struct {
	path           string
	name           string
	aliases        []string
	filenames      []string
	aliasFilenames []string
	mimeTypes      []string
	analyse        bool
	// lexer is what the entry resolved to, once something asked for it.
	lexer chroma.Lexer
}

var (
	mu    sync.Mutex
	index []*entry
	// byName and byAlias map what an embedded lexer can be found by to it,
	// under its name and its lowercased one.
	byName, byAlias map[string]*entry
	indexOnce       sync.Once
	// known maps the name and aliases of every lexer registered so far, and
	// their lowercased forms, to it. A lexer a Go file registers under an
	// embedded lexer's name is the newer definition, and stands in for it.
	known = map[string]chroma.Lexer{}
)

func buildIndex() {
	indexOnce.Do(func() {
		byName, byAlias = map[string]*entry{}, map[string]*entry{}
		paths, err := fs.Glob(embedded, "embedded/*.xml")
		if err != nil {
			panic(err)
		}
		for _, path := range paths {
			e, err := readEntry(path)
			if err != nil {
				panic(err)
			}
			index = append(index, e)
			byName[e.name] = e
			byName[strings.ToLower(e.name)] = e
			for _, alias := range e.aliases {
				byAlias[alias] = e
				byAlias[strings.ToLower(alias)] = e
			}
		}
	})
}

// readEntry reads the config at the head of an embedded lexer, leaving its
// rules in the file.
func readEntry(path string) (*entry, error) {
	f, err := embedded.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var config struct {
		Name           string    `xml:"name"`
		Aliases        []string  `xml:"alias"`
		Filenames      []string  `xml:"filename"`
		AliasFilenames []string  `xml:"alias_filename"`
		MimeTypes      []string  `xml:"mime_type"`
		Analyse        *struct{} `xml:"analyse"`
	}
	decoder := xml.NewDecoder(f)
	for {
		token, err := decoder.Token()
		if err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		start, ok := token.(xml.StartElement)
		if !ok || start.Name.Local != "config" {
			continue
		}
		if err := decoder.DecodeElement(&config, &start); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		return &entry{
			path:           path,
			name:           config.Name,
			aliases:        config.Aliases,
			filenames:      config.Filenames,
			aliasFilenames: config.AliasFilenames,
			mimeTypes:      config.MimeTypes,
			analyse:        config.Analyse != nil,
		}, nil
	}
}

// standIn is the lexer registered under the entry's name, if one is: the
// registration replaces the lexer the file defines. mu must be held.
func (e *entry) standIn() chroma.Lexer {
	return known[e.name]
}

// resolve returns the lexer the entry stands for, building it the first time.
// mu must be held.
func (e *entry) resolve() chroma.Lexer {
	if e.lexer != nil {
		return e.lexer
	}
	if lexer := e.standIn(); lexer != nil {
		e.lexer = lexer
		return lexer
	}
	e.lexer = register(chroma.MustNewXMLLexer(embedded, e.path))
	return e.lexer
}

// patterns is the file patterns the entry matches, from the lexer standing in
// for it when there is one. mu must be held.
func (e *entry) patterns(alias bool) []string {
	if lexer := e.standIn(); lexer != nil {
		if alias {
			return lexer.Config().AliasFilenames
		}
		return lexer.Config().Filenames
	}
	if alias {
		return e.aliasFilenames
	}
	return e.filenames
}

// hasAnalyser is whether the entry's lexer may score text it is given. mu must
// be held.
func (e *entry) hasAnalyser() bool {
	return e.analyse || e.standIn() != nil
}

// register adds a lexer to the registry, and remembers what it can be found
// by. mu must be held.
func register(lexer chroma.Lexer) chroma.Lexer {
	GlobalLexerRegistry.Register(lexer)
	config := lexer.Config()
	known[config.Name] = lexer
	known[strings.ToLower(config.Name)] = lexer
	for _, alias := range config.Aliases {
		known[alias] = lexer
		known[strings.ToLower(alias)] = lexer
	}
	return lexer
}

// others are the lexers the registry holds besides the embedded ones, which
// match, Analyse and Names reach through the index. mu must be held.
func others(yield func(chroma.Lexer)) {
	for _, lexer := range GlobalLexerRegistry.Lexers {
		if e := byName[lexer.Config().Name]; e != nil && e.standIn() == lexer {
			continue
		}
		yield(lexer)
	}
}

// Get a Lexer by name, alias or file extension.
//
// Note that if there isn't an exact match on name or alias, this will call
// Match(), so it is not efficient.
func Get(name string) chroma.Lexer {
	mu.Lock()
	defer mu.Unlock()
	buildIndex()
	if lexer, ok := known[name]; ok {
		return lexer
	}
	if lexer, ok := known[strings.ToLower(name)]; ok {
		return lexer
	}
	if e := byName[name]; e != nil {
		return e.resolve()
	}
	if e := byName[strings.ToLower(name)]; e != nil {
		return e.resolve()
	}
	if e := byAlias[name]; e != nil {
		return e.resolve()
	}
	if e := byAlias[strings.ToLower(name)]; e != nil {
		return e.resolve()
	}
	candidates := chroma.PrioritisedLexers{}
	// Try file extension.
	if lexer := match("filename." + name); lexer != nil {
		candidates = append(candidates, lexer)
	}
	// Try exact filename.
	if lexer := match(name); lexer != nil {
		candidates = append(candidates, lexer)
	}
	if len(candidates) == 0 {
		return nil
	}
	sort.Sort(candidates)
	return candidates[0]
}

// Names of all lexers, optionally including aliases.
func Names(withAliases bool) []string {
	mu.Lock()
	defer mu.Unlock()
	buildIndex()
	out := make([]string, 0, len(index))
	for _, e := range index {
		out = append(out, e.name)
		if withAliases {
			out = append(out, e.aliases...)
		}
	}
	others(func(lexer chroma.Lexer) {
		out = append(out, lexer.Config().Name)
		if withAliases {
			out = append(out, lexer.Config().Aliases...)
		}
	})
	sort.Strings(out)
	return out
}

// Aliases of all the lexers, and skip those lexers who do not have any
// aliases, or show their name instead
func Aliases(skipWithoutAliases bool) []string {
	mu.Lock()
	defer mu.Unlock()
	buildIndex()
	out := []string{}
	add := func(config *chroma.Config) {
		if len(config.Aliases) == 0 {
			if skipWithoutAliases {
				return
			}
			out = append(out, config.Name)
		}
		out = append(out, config.Aliases...)
	}
	for _, e := range index {
		if lexer := e.standIn(); lexer != nil {
			add(lexer.Config())
			continue
		}
		if len(e.aliases) == 0 && skipWithoutAliases {
			continue
		}
		out = append(out, e.aliases...)
		if len(e.aliases) == 0 {
			out = append(out, e.name)
		}
	}
	others(func(lexer chroma.Lexer) { add(lexer.Config()) })
	sort.Strings(out)
	return out
}

// Match returns the first lexer matching filename.
//
// Note that this iterates over all file patterns in all lexers, so it's not
// particularly efficient.
func Match(filename string) chroma.Lexer {
	mu.Lock()
	defer mu.Unlock()
	buildIndex()
	return match(filename)
}

func match(filename string) chroma.Lexer {
	filename = filepath.Base(filename)
	// Primary file patterns decide on their own; only when no lexer claims
	// the name does a secondary pattern.
	for _, alias := range []bool{false, true} {
		matched := chroma.PrioritisedLexers{}
		for _, e := range index {
			for _, glob := range e.patterns(alias) {
				if globMatch(glob, filename) {
					matched = append(matched, e.resolve())
					break
				}
			}
		}
		others(func(lexer chroma.Lexer) {
			config := lexer.Config()
			patterns := config.Filenames
			if alias {
				patterns = config.AliasFilenames
			}
			for _, glob := range patterns {
				if globMatch(glob, filename) {
					matched = append(matched, lexer)
					break
				}
			}
		})
		if len(matched) > 0 {
			sort.Sort(matched)
			return matched[0]
		}
	}
	return nil
}

// globMatch reports whether filename matches a lexer's pattern, or the pattern
// with the suffix an editor or a build tool leaves on a file of the same
// language.
func globMatch(glob, filename string) bool {
	ok, err := filepath.Match(glob, filename)
	if err != nil {
		panic(err)
	}
	if ok {
		return true
	}
	for _, suffix := range chroma.IgnoredSuffixes {
		ok, err := filepath.Match(glob+suffix, filename)
		if err != nil {
			panic(err)
		}
		if ok {
			return true
		}
	}
	return false
}

// MatchMimeType attempts to find a lexer for the given MIME type.
func MatchMimeType(mimeType string) chroma.Lexer {
	mu.Lock()
	defer mu.Unlock()
	buildIndex()
	matched := chroma.PrioritisedLexers{}
	for _, e := range index {
		mimeTypes := e.mimeTypes
		if lexer := e.standIn(); lexer != nil {
			mimeTypes = lexer.Config().MimeTypes
		}
		for _, mime := range mimeTypes {
			if mimeType == mime {
				matched = append(matched, e.resolve())
				break
			}
		}
	}
	others(func(lexer chroma.Lexer) {
		for _, mime := range lexer.Config().MimeTypes {
			if mimeType == mime {
				matched = append(matched, lexer)
				break
			}
		}
	})
	if len(matched) == 0 {
		return nil
	}
	sort.Sort(matched)
	return matched[0]
}

// Register a Lexer with the global registry.
func Register(lexer chroma.Lexer) chroma.Lexer {
	mu.Lock()
	defer mu.Unlock()
	return register(lexer)
}

// Analyse text content and return the "best" lexer.
func Analyse(text string) chroma.Lexer {
	mu.Lock()
	defer mu.Unlock()
	buildIndex()
	var picked chroma.Lexer
	highest := float32(0.0)
	score := func(lexer chroma.Lexer) {
		if analyser, ok := lexer.(chroma.Analyser); ok {
			if weight := analyser.AnalyseText(text); weight > highest {
				picked, highest = lexer, weight
			}
		}
	}
	for _, e := range index {
		if e.hasAnalyser() {
			score(e.resolve())
		}
	}
	others(score)
	return picked
}

// PlaintextRules is used for the fallback lexer as well as the explicit
// plaintext lexer.
func PlaintextRules() chroma.Rules {
	return chroma.Rules{
		"root": []chroma.Rule{
			{`.+`, chroma.Text, nil},
			{`\n`, chroma.Text, nil},
		},
	}
}

// Fallback lexer if no other is found.
var Fallback chroma.Lexer = chroma.MustNewLexer(&chroma.Config{
	Name:      "fallback",
	Filenames: []string{"*"},
	Priority:  -1,
}, PlaintextRules)
