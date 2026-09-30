package daemon

import (
	"encoding/json"
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
	MimeType ImageMimeType `json:"mimeType"`
	Width    int           `json:"width"`
	Height   int           `json:"height"`
	Bytes    int           `json:"bytes"`
}

type ImageAttachment struct {
	ImageMetadata
	Data string `json:"data"`
}

var validMimeTypes = map[ImageMimeType]bool{
	ImagePNG:  true,
	ImageJPEG: true,
	ImageWEBP: true,
}

// ParseImageMetadata validates raw image metadata fields and returns nil if invalid.
func ParseImageMetadata(val any) *ImageMetadata {
	if val == nil {
		return nil
	}

	data, err := json.Marshal(val)
	if err != nil {
		return nil
	}

	var meta ImageMetadata
	if err := json.Unmarshal(data, &meta); err != nil {
		return nil
	}

	if !validMimeTypes[meta.MimeType] {
		return nil
	}

	if meta.Width < 1 || meta.Width > 16384 {
		return nil
	}
	if meta.Height < 1 || meta.Height > 16384 {
		return nil
	}
	if int64(meta.Width)*int64(meta.Height) > 40_000_000 {
		return nil
	}
	if meta.Bytes < 1 || meta.Bytes > 5*1024*1024 {
		return nil
	}

	return &meta
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
