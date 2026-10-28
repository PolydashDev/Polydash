import { PutObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { createS3Client, getBucketConfig } from './aws-config';

const s3 = createS3Client();

export async function generatePresignedUploadUrl(fileName: string, contentType: string, isPublic = true) {
  const { bucketName, folderPrefix } = getBucketConfig();
  const cloud_storage_path = isPublic
    ? `${folderPrefix}public/uploads/${Date.now()}-${fileName}`
    : `${folderPrefix}uploads/${Date.now()}-${fileName}`;
  const uploadUrl = await getSignedUrl(
    s3,
    new PutObjectCommand({ Bucket: bucketName, Key: cloud_storage_path, ContentType: contentType }),
    { expiresIn: 3600 },
  );
  return { uploadUrl, cloud_storage_path };
}

export async function getPublicFileUrl(cloud_storage_path: string) {
  const { bucketName } = getBucketConfig();
  const region = (await s3.config.region()) || process.env.AWS_REGION || 'us-east-1';
  const key = cloud_storage_path.split('/').map(encodeURIComponent).join('/');
  return `https://${bucketName}.s3.${region}.amazonaws.com/${key}`;
}
