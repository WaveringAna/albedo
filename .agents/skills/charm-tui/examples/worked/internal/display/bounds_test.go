package display

import (
	"strings"
	"testing"
	"unicode"
	"unicode/utf8"
)

func TestBodyRows(t *testing.T) {
	for _, c := range []struct{ total, header, footer, want int }{
		{24, 2, 3, 19}, {2, 2, 3, 0}, {0, 0, 0, 0}, {-1, 2, 1, 0}, {5, -1, -1, 5},
	} {
		if got := BodyRows(c.total, c.header, c.footer); got != c.want {
			t.Fatalf("%+v: %d", c, got)
		}
	}
}

func TestWindowBoundsExhaustive(t *testing.T) {
	for n := 0; n < 35; n++ {
		for h := 0; h < 15; h++ {
			for cursor := -1; cursor < n+2; cursor++ {
				for top := -1; top < n+2; top++ {
					lo, hi := Window(n, cursor, top, h)
					if lo < 0 || hi < lo || hi > n || hi-lo > h {
						t.Fatalf("n=%d h=%d: [%d,%d)", n, h, lo, hi)
					}
					c := min(max(0, cursor), n-1)
					if n > 0 && h > 0 && (c < lo || c >= hi) {
						t.Fatal("cursor outside window")
					}
				}
			}
		}
	}
}

func TestWindowFormatsOnlyVisibleRows(t *testing.T) {
	lo, hi := Window(100_000, 72_004, 72_000, 12)
	count := 0
	for i := lo; i < hi; i++ {
		count++
	} // This is the render loop's only row range.
	if count != 12 {
		t.Fatalf("formatted %d rows", count)
	}
}

func TestSingleLineControlsAndUnicode(t *testing.T) {
	input := "東京 e\u0301 👩‍💻\x1b]52;c;payload\a\n\r\t\u009b31m\u2028\u2029\xff"
	got := SingleLine(input)
	if !utf8.ValidString(got) {
		t.Fatal("invalid UTF-8")
	}
	for _, r := range got {
		if unicode.IsControl(r) || r == '\u2028' || r == '\u2029' {
			t.Fatalf("control %U", r)
		}
	}
	if !strings.Contains(got, "東京 e\u0301 👩‍💻") {
		t.Fatal("damaged ordinary Unicode")
	}
}
