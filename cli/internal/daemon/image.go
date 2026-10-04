package daemon

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
