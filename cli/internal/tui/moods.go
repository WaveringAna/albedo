package tui

import (
	"fmt"
	"time"
)

// A mood is a class of moment in a turn. Each class owns its own faces, so a
// face always means something: what albedo is doing, or how a turn ended.
type mood string

const (
	moodPreparing  mood = "preparing"
	moodThinking   mood = "thinking"
	moodResponding mood = "responding"
	moodWorking    mood = "working"
	moodCompacting mood = "compacting"
	moodStopping   mood = "stopping"

	moodDone    mood = "done"
	moodQuick   mood = "quick"
	moodLong    mood = "long"
	moodTired   mood = "tired"
	moodFailed  mood = "failed"
	moodStopped mood = "stopped"
)

// Faces avoid combining marks and right-to-left letters, which terminals
// disagree on.
//
// A phase owns a pool of animations and each turn plays one of them. A face
// keeps its parentheses in place across frames: only eyes, mouth, and what
// follows the face move.
var animations = map[mood][][]string{
	moodPreparing: {{"(・・ )", "( ・・)"}},
	moodThinking: {
		{"( ˘ω˘ )", "( ˘ω˘ ).", "( ˘ω˘ )..", "( ˘ω˘ )..."},
		{"(・ω・ )", "( ・ω・)", "(・ω・ )?", "( ・ω・)?"},
		{"(´-ω-`)", "(´･ω･`)", "(´-ω-`)", "(´･ω･`)!"},
	},
	moodResponding: {
		{"(ˊᗜˋ )", "(ˊ-ˋ )", "( ˊᗜˋ)", "( ˊ-ˋ)"},
		{"(˶ᵔ ᗜ ᵔ˶)", "(˶ᵔ ᵕ ᵔ˶)"},
		{"(・ᗜ・)", "(・-・)", "(・ᗜ・)ﾉ", "(・-・)ﾉ"},
	},
	moodWorking: {
		{"(˶•ᴗ•)ｶﾀ", "(˶•ᴗ•)ｶﾀｶﾀ", "(˶•ᴗ•)ｶﾀｶﾀｶﾀ"},
		{"(・_・ )", "( ・_・)", "(・ᴗ・ )✧"},
		{"(っ•ᴗ•)っ･", "(っ•ᴗ•)っ ･", "(っ•ᴗ•)っ  ･"},
		{"ヽ(･ω･)ﾉ", "ヾ(･ω･)ﾉ"},
		{"(๑•ᴗ•)", "(๑•ᴗ•)✧", "(๑•ᴗ•) ✧"},
	},
	moodCompacting: {{"(>_<)", "(>.<)"}},
	moodStopping:   {{"(・_・;)"}},
}

// An outcome owns a pool of faces and each turn shows one of them.
// Additional faces come from https://wikileaks.org/ciav7p1/cms/page_17760284.html.
var faces = map[mood][]string{
	moodDone:    {"(˶ᵔ ᵕ ᵔ˶)", "(๑˃ᴗ˂)", "ヽ(・∀・)ﾉ", "(ᵔᴥᵔ)", "(っ˘ω˘ς)", "(◕‿◕)", "(✿◠‿◠)", "(o´ω｀o)", "☻_☻", "ᶘ ᵒᴥᵒᶅ"},
	moodQuick:   {"(・ω・)ノ", "(｀・ω・´)", "(^_−)☆", "(^▽^)"},
	moodLong:    {"(ง ˃ᴗ˂)ง", "(๑˃ᴗ˂)✧", "(ˊᗜˋ*)✧", "o(≧∀≦)o", "(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧"},
	moodTired:   {"(￣ー￣;)ゞ", "(・ω・;)ゞ", "( ˘ᴗ˘ )ﾌｩ", "(´-ω-`)zzZ", "_(:3 」∠)_", "(︶ω︶)", "(-＿- )ノ", "(n˘v˘•)¬"},
	moodFailed:  {"(╥﹏╥)", "(｡•︿•｡)", "(っ- ‸ – ς)", "(ಥ﹏ಥ)", "(╥_╥)", "☹_☹", "(ಠ~ಠ)", "(ಡ_ಡ)", "(ತಎತ)", "(ತ_ತ)", "(ಥдಥ)"},
	moodStopped: {"(・_・;)", "(°ロ°)", "(￣□￣;)", "(ಠ_ಠ)", "(°Д°)"},
}

// pick chooses from n by seed, salted by the mood so one turn's picks for
// different moods do not move in step.
func (m mood) pick(seed int64, n int) int {
	return int(fnv1a(uint64(seed), string(m)) % uint64(n))
}

// face picks a stable face for seed, so a rebuilt transcript keeps its faces.
func (m mood) face(seed int64) string {
	set := faces[m]
	return set[m.pick(seed, len(set))]
}

// faceInterval is how long each frame of an animation shows.
const faceInterval = 500 * time.Millisecond

// frame is the turn's animation at tick, one frame per faceInterval.
func (m mood) frame(seed int64, tick int) string {
	pool := animations[m]
	set := pool[m.pick(seed, len(pool))]
	return set[tick%len(set)]
}

// outcome classes a finished turn by how it ended and how long it took.
func outcome(failed, stopped bool, elapsedMs int64) mood {
	switch {
	case stopped:
		return moodStopped
	case failed:
		return moodFailed
	case elapsedMs > 10*60_000:
		return moodTired
	case elapsedMs >= 3*60_000:
		return moodLong
	case elapsedMs > 0 && elapsedMs < 4_000:
		return moodQuick
	}
	return moodDone
}

func formatElapsed(ms int64) string {
	s := ms / 1000
	switch {
	case s < 60:
		return fmt.Sprintf("%ds", s)
	case s < 3600:
		return fmt.Sprintf("%dm %ds", s/60, s%60)
	}
	return fmt.Sprintf("%dh %dm", s/3600, s/60%60)
}

// formatGap is how long you were away, in the largest whole unit.
func formatGap(ms int64) string {
	m := ms / 60_000
	switch {
	case m < 60:
		return fmt.Sprintf("%dm later", m)
	case m < 48*60:
		return fmt.Sprintf("%dh later", m/60)
	}
	return fmt.Sprintf("%dd later", m/(24*60))
}
