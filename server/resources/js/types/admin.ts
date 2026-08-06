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

export type AdminEntitlement = {
    email: string;
    pack_slug: string;
    source: string;
    granted_at: string;
    revoked_at: string | null;
};
