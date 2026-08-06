<?php

namespace App\Http\Controllers\Api\V1\Admin;

use App\Actions\Admin\StoreUploadedAsset;
use App\Http\Controllers\Controller;
use App\Http\Requests\Admin\StoreAssetRequest;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\UploadedFile;
use Symfony\Component\HttpFoundation\Response;

/**
 * `POST /api/v1/admin/assets` — §11's `{asset_ulid, sha256}`.
 *
 * Always a `201`, even when the bytes were already there: the response is a
 * statement about where the asset *is*, and a client that has to distinguish
 * "created" from "already had it" is one that will start branching on it.
 * Content addressing makes re-uploading harmless by construction.
 */
class AssetController extends Controller
{
    public function __invoke(StoreAssetRequest $request, StoreUploadedAsset $store): JsonResponse
    {
        /** @var UploadedFile $file */
        $file = $request->file('file');

        $asset = $store->handle($file, (string) $request->string('kind'));

        return response()->json([
            'asset_ulid' => $asset->ulid,
            'sha256' => $asset->sha256,
            'kind' => $asset->kind,
            'bytes' => $asset->bytes,
        ], Response::HTTP_CREATED);
    }
}
