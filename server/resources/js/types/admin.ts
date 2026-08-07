export type AdminPack = {
    slug: string;
    title: string;
    blurb: string | null;
    status: 'draft' | 'published' | 'retired';
    is_free: boolean;
    sort_order: number;
    cover: string | null;
    cover_url: string | null;
    version_count: number;
    latest_published_version: number | null;
    created_at: string | null;
};

export type AdminPackVersion = {
    version: number;
    status: 'draft' | 'published';
    published_at: string | null;
    created_at: string | null;
    min_client_version: string | null;
    bytes: number;
    sha256: string;
    book_count: number;
    page_count: number;
};

export type AdminPreviewPage = {
    book_uid: string;
    book_title: string;
    page_index: number;
    title: string | null;
    image_size: [number, number] | null;
    region_count: number | null;
    preview_url: string;
};

/** BL-24 — web authoring (DLC_SERVER.md §10.3). */
export type AuthoredAsset = {
    ulid: string;
    sha256: string;
    bytes: number;
    width: number | null;
    height: number | null;
    kind: string;
};

export type AuthoredPageMappingStatus =
    'pending' | 'queued' | 'running' | 'mapped' | 'failed';

export type AuthoredPage = {
    ulid: string;
    page_index: number;
    title: string | null;
    file_stem: string;
    display: AuthoredAsset | null;
    mask: AuthoredAsset | null;
    has_mask: boolean;
    shipped_mask: AuthoredAsset | null;
    idmap: AuthoredAsset | null;
    regions: AuthoredAsset | null;
    image_size: [number, number] | null;
    region_count: number | null;
    mapping_status: AuthoredPageMappingStatus;
    mapping_error: string | null;
    mapping_log: string | null;
    mapped_at: string | null;
    validation_errors: string[];
    validation_warnings: string[];
    publishable: boolean;
    blockers: string[];
    tuning: Record<string, number> | null;
    effective_tuning: Record<string, number>;
    preview_url: string | null;
    status_url: string;
};

export type AuthoredBook = {
    book_uid: string;
    title: string;
    blurb: string | null;
    pack_slug: string;
    pack_status: 'draft' | 'published' | 'retired';
    is_free: boolean;
    page_count: number;
    unpublishable_page_count: number;
    latest_published_version: number | null;
    publishable: boolean;
    blockers: string[];
    created_at: string | null;
    updated_at: string | null;
    pages?: AuthoredPage[];
};

/**
 * BL-37 — sticker sets. Deliberately shorter than a page: a sticker has no
 * regions, so there is no mapping status, no tuning and no derived artifacts.
 */
export type AuthoredSticker = {
    ulid: string;
    sticker_index: number;
    sticker_id: string;
    title: string | null;
    file_name: string;
    image: AuthoredAsset | null;
    image_size: [number, number] | null;
    validation_errors: string[];
    validation_warnings: string[];
    publishable: boolean;
    blockers: string[];
    image_url: string;
};

export type AuthoredStickerSet = {
    set_uid: string;
    title: string;
    blurb: string | null;
    sort_order: number;
    pack_slug: string;
    pack_kind: 'book' | 'sticker_set';
    pack_status: 'draft' | 'published' | 'retired';
    is_free: boolean;
    sticker_count: number;
    unpublishable_sticker_count: number;
    latest_published_version: number | null;
    publishable: boolean;
    blockers: string[];
    created_at: string | null;
    updated_at: string | null;
    stickers?: AuthoredSticker[];
};

export type AdminEntitlement = {
    email: string;
    pack_slug: string;
    source: string;
    granted_at: string;
    revoked_at: string | null;
};
