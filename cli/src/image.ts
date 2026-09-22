export type ImageMimeType = "image/png" | "image/jpeg" | "image/webp"
export type ImageMetadata = { mimeType: ImageMimeType; width: number; height: number; bytes: number }
export type ImageAttachment = ImageMetadata & { data: string }

const MIME_TYPES = new Set<ImageMimeType>(["image/png", "image/jpeg", "image/webp"])

export function parseImageMetadata(value: unknown): ImageMetadata | undefined {
  if (!value || typeof value !== "object") return
  const image = value as Partial<ImageMetadata>
  if (!MIME_TYPES.has(image.mimeType as ImageMimeType) ||
      !Number.isSafeInteger(image.width) || !Number.isSafeInteger(image.height) || !Number.isSafeInteger(image.bytes) ||
      (image.width ?? 0) < 1 || (image.width ?? 0) > 16_384 ||
      (image.height ?? 0) < 1 || (image.height ?? 0) > 16_384 ||
      (image.width ?? 0) * (image.height ?? 0) > 40_000_000 ||
      (image.bytes ?? 0) < 1 || (image.bytes ?? 0) > 5 * 1024 * 1024) return
  return image as ImageMetadata
}

export const imageLabel = ({ mimeType, width, height, bytes }: ImageMetadata): string => {
  const size = bytes >= 1024 * 1024 ? `${(bytes / 1024 / 1024).toFixed(1)} MB` : bytes >= 1024 ? `${Math.ceil(bytes / 1024)} KB` : `${bytes} B`
  return `${mimeType.slice(6).toUpperCase()} ${width}×${height} · ${size}`
}
