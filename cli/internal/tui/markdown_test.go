// Streaming Markdown must render every partial reply exactly as its settled
// form: the daemon e2e sees committed transcript text only, never the live
// view, so it cannot sample the streaming boundaries this sweep does.
package tui

import (
	"strings"
	"testing"
)

var markdownSamples = []string{
	"shown as source:\n\n```md\n[x]: https://example.com\n<!-- note -->\n```\n\nsee [x] and <pre>\n\nafter",
	`fixed in ` + "`" + `25424ba` + "`" + ` "keep row backgrounds across lip gloss v2 resets". lipgloss v2 closes styled text with the short reset ` + "`" + `\x1b[m` + "`" + `, where v1 used ` + "`" + `\x1b[0m` + "`" + `.

i also measured cpu over 45 seconds while you were testing:

| pid | binary | cpu |
|---|---|---|
| 84082 | new (` + "`" + `cli/bin/albedo` + "`" + `, this session) | ~4% |
| 58609 | old nix one | ~13.5% |

don't read too much into the new binary's number.`,
	`**what port-chat did:**
- **paste:** ` + "`" + `chat.go` + "`" + ` never had a special case for paste. in v1, pasted text arrived as a key event.
- **mouse:** it's one ` + "`" + `case tea.MouseMsg:` + "`" + ` with an inner switch.

**things i'll change in my own pass:**
- remove a porting-only comment.
- run ` + "`" + `go mod tidy` + "`" + `.

once port-forms reports back i'll do the full review.`,
	`the migration is big but mostly mechanical. the main ones i expect:
- ` + "`" + `tea.KeyMsg` + "`" + ` with ` + "`" + `.Type` + "`" + `/` + "`" + `.Runes` + "`" + ` becomes ` + "`" + `tea.KeyPressMsg` + "`" + `.
- mouse messages get split up.

1. use a static cursor there too.
2. let the terminal blink its own cursor.

` + "`" + `` + "`" + `` + "`" + `sh
ps -o %cpu= -p $(pgrep -n albedo)
` + "`" + `` + "`" + `` + "`" + `

run it a few times.

### heading three
text under heading

> a quote
> continues

after quote

    indented code

final *line* here
`,
	`- item

  continued inside item

- second item

next para

1. one

   nested para

2. two

~~~
tilde fence

still fence
~~~

done`,
	`intro

` + "`" + `` + "`" + `` + "`" + `go
func a() {

	return
}
` + "`" + `` + "`" + `` + "`" + `
## after code heading
para

---

tail`,
}

// Block by block, every prefix renders exactly as the whole prefix does, and
// no block boundary falls inside a code fence: a split fence renders the same
// text but re-renders the whole tail on every streaming chunk.
func TestMarkdownRendersTheSameBlockByBlock(t *testing.T) {
	for _, width := range []int{40, 98} {
		for i, sample := range markdownSamples {
			blocks := markdownBlocks(sample)
			if len(blocks) < 2 {
				t.Fatalf("sample %d is one block, so it tests nothing", i)
			}
			fence := ""
			for _, block := range blocks {
				if fence != "" {
					t.Fatalf("sample %d splits a code fence between blocks", i)
				}
				for _, line := range strings.Split(block, "\n") {
					fence = fenceAfter(fence, line)
				}
			}
			for end := 1; end <= len(sample); end += 7 {
				text := sample[:end]
				if got, want := RenderMarkdownAnsi(text, width), strings.Trim(renderMarkdown(text, width), " \n"); got != want {
					t.Fatalf("sample %d at %d, width %d:\n got %q\nwant %q", i, end, width, got, want)
				}
			}
		}
	}
}
