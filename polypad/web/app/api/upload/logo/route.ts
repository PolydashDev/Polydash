import { NextResponse } from 'next/server';
import { generatePresignedUploadUrl, getPublicFileUrl } from '@/lib/s3';

export const dynamic = 'force-dynamic';

const ALLOWED: Record<string, string> = {
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/webp': 'webp',
  'image/gif': 'gif',
};
const MAX_BYTES = 5 * 1024 * 1024;

export async function POST(req: Request) {
  try {
    const body = await req.json().catch(() => ({}));
    const contentType = String(body?.contentType ?? '');
    const size = Number(body?.size ?? 0);
    const ext = ALLOWED[contentType];
    if (!ext) {
      return NextResponse.json({ error: 'Use a PNG, JPG, WEBP or GIF image.' }, { status: 400 });
    }
    if (!size || size > MAX_BYTES) {
      return NextResponse.json({ error: 'Image must be 5 MB or smaller.' }, { status: 400 });
    }
    const fileName = `token-logos/${crypto.randomUUID()}.${ext}`;
    const { uploadUrl, cloud_storage_path } = await generatePresignedUploadUrl(fileName, contentType, true);
    const publicUrl = await getPublicFileUrl(cloud_storage_path);
    return NextResponse.json({ uploadUrl, cloud_storage_path, publicUrl });
  } catch (e) {
    console.error('logo presign failed', e);
    return NextResponse.json({ error: 'Could not prepare upload.' }, { status: 500 });
  }
}
