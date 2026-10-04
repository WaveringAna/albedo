package daemon

import (
	"fmt"
	"strings"
)

type ImageMimeType string

const (
	ImagePNG  ImageMimeType = "image/png"
	ImageJPEG ImageMimeType = "image/jpeg"
	ImageWEBP ImageMimeType = "image/webp"
)

type ImageMetadata struct {
	MimeType ImageMimeType `json:"mime_type"`
	Width    int           `json:"width"`
	Height   int           `json:"height"`
	Bytes    int           `json:"bytes"`
}

type ImageAttachment struct {
	Data string `json:"data"`
	ImageMetadata
}

// ImageLabel returns human-readable label for image metadata.
func ImageLabel(meta ImageMetadata) string {
	var size string
	if meta.Bytes >= 1024*1024 {
		size = fmt.Sprintf("%.1f MB", float64(meta.Bytes)/1024.0/1024.0)
	} else if meta.Bytes >= 1024 {
		size = fmt.Sprintf("%d KB", (meta.Bytes+1023)/1024)
	} else {
		size = fmt.Sprintf("%d B", meta.Bytes)
	}

	prefix := strings.ToUpper(strings.TrimPrefix(string(meta.MimeType), "image/"))

	return fmt.Sprintf("%s %d×%d · %s", prefix, meta.Width, meta.Height, size)
}
