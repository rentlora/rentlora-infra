const { S3Client, GetObjectCommand, PutObjectCommand } = require("@aws-sdk/client-s3");
const sharp = require("sharp");

const s3 = new S3Client({});
const MAX_WIDTH  = parseInt(process.env.MAX_WIDTH  || "1200");
const MAX_HEIGHT = parseInt(process.env.MAX_HEIGHT || "900");

exports.handler = async (event) => {
  const bucket = event.Records[0].s3.bucket.name;
  const key    = decodeURIComponent(event.Records[0].s3.object.key.replace(/\+/g, " "));

  // Only process original uploads, not already-resized
  if (key.includes("/resized/")) return;

  const obj = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
  const buffer = Buffer.concat(await obj.Body.toArray());

  const resized = await sharp(buffer)
    .resize(MAX_WIDTH, MAX_HEIGHT, { fit: "inside", withoutEnlargement: true })
    .jpeg({ quality: 85 })
    .toBuffer();

  const resizedKey = key.replace("uploads/", "uploads/resized/");
  await s3.send(new PutObjectCommand({
    Bucket:      bucket,
    Key:         resizedKey,
    Body:        resized,
    ContentType: "image/jpeg",
    CacheControl: "max-age=31536000",
  }));
};
