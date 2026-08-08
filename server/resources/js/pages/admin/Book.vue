<script setup lang="ts">
import { Form, Head, Link } from '@inertiajs/vue3';
import ConfirmDialog from '@/components/ConfirmDialog.vue';
import Heading from '@/components/Heading.vue';
import InputError from '@/components/InputError.vue';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { formatDateTime } from '@/lib/datetime';
import type { AuthoredBook, AuthoredPage } from '@/types/admin';

/**
 * One colouring book: its cover, and its pages as picture rows (BL-38).
 *
 * The old screen listed pages as text with a region overlay beside them, which
 * answered "did the mapping work" and not "which drawing is this". An artist
 * scanning their own book is looking at the art, so every row now shows the
 * **detail image and the masking image**, each one replaceable in place, with
 * an empty slot where a mask could go — the mask is optional and its absence is
 * a normal page, not a gap.
 *
 * Every delete goes through a modal. There is no undo anywhere below this
 * screen: a removed page takes its mapping with it, and a removed book takes
 * the workspace.
 */
const props = defineProps<{
    book: AuthoredBook;
    publishErrors: string[];
}>();

defineOptions({
    layout: {
        breadcrumbs: [{ title: 'Books', href: '/admin/books' }],
    },
});

const base = `/admin/books/${props.book.book_uid}`;

const statusClass: Record<string, string> = {
    pending: 'bg-muted text-muted-foreground',
    queued: 'bg-muted text-muted-foreground',
    running: 'bg-sky-100 text-sky-900 dark:bg-sky-900/40 dark:text-sky-200',
    mapped: 'bg-emerald-100 text-emerald-900 dark:bg-emerald-900/40 dark:text-emerald-200',
    failed: 'bg-destructive/15 text-destructive',
};

function pageSummary(page: AuthoredPage): string {
    const size = page.image_size
        ? `${page.image_size[0]}×${page.image_size[1]}`
        : '—';
    const regions = page.region_count ?? '—';

    return `${size} · ${regions} region(s)`;
}

function pageLabel(page: AuthoredPage): string {
    return page.title ?? page.file_stem;
}
</script>

<template>
    <Head :title="book.title" />

    <div class="flex h-full flex-1 flex-col gap-6 p-4">
        <div class="flex flex-wrap items-start justify-between gap-3">
            <Heading
                :title="book.title"
                :description="`${book.book_uid} · pack ${book.pack_slug} (${book.pack_status})${book.is_free ? ' · free' : ''}`"
            />

            <div class="flex flex-wrap items-center gap-2">
                <Button variant="ghost" as-child>
                    <Link :href="`/admin/packs/${book.pack_slug}`">Pack</Link>
                </Button>

                <ConfirmDialog
                    :action="base"
                    method="delete"
                    trigger-label="Delete coloring book"
                    trigger-variant="outline"
                    trigger-size="default"
                    data-test="delete-book"
                    confirm-data-test="confirm-delete-book"
                    :confirm-label="
                        book.latest_published_version
                            ? 'Remove and retire'
                            : 'Delete book'
                    "
                    :title="`Delete “${book.title}”?`"
                    :description="
                        book.latest_published_version
                            ? 'This book has been published, so removing it retires its pack — households that own it keep it. The authoring workspace, and every page in it, is deleted.'
                            : 'This book has never been published, so removing it deletes it outright, together with every page in it. There is no undo.'
                    "
                />

                <Form
                    :action="`${base}/publish`"
                    method="post"
                    v-slot="{ processing }"
                >
                    <Button
                        type="submit"
                        data-test="publish-book"
                        :disabled="processing || !book.publishable"
                    >
                        {{
                            processing ? 'Publishing…' : 'Publish coloring book'
                        }}
                    </Button>
                </Form>
            </div>
        </div>

        <!-- Every reason at once. A book with three unmapped pages should say
             so once, not three times across three attempts. -->
        <div
            v-if="publishErrors.length > 0"
            class="rounded-lg border border-destructive/50 bg-destructive/5 p-4"
        >
            <p class="font-medium text-destructive">
                This book is not ready to publish.
            </p>
            <ul
                class="mt-2 list-disc space-y-1 pl-5 text-sm text-muted-foreground"
            >
                <li v-for="(error, i) in publishErrors" :key="i">
                    {{ error }}
                </li>
            </ul>
        </div>

        <div class="grid gap-6 lg:grid-cols-[20rem_minmax(0,1fr)]">
            <!-- ------------------------------------------------- cover --- -->
            <div class="flex h-fit flex-col gap-4 rounded-lg border p-4">
                <Heading
                    variant="small"
                    title="Cover"
                    description="Optional. The bookshelf and the open/close animation use it; without one the game falls back to page one."
                />

                <div class="flex items-start gap-4">
                    <img
                        v-if="book.cover_url"
                        :src="book.cover_url"
                        :alt="`Cover of ${book.title}`"
                        data-test="book-cover"
                        class="size-28 rounded border object-contain"
                    />
                    <div
                        v-else
                        class="flex size-28 items-center justify-center rounded border border-dashed p-2 text-center text-xs text-muted-foreground"
                    >
                        No cover yet
                    </div>

                    <div class="grid gap-2">
                        <Form
                            :action="base"
                            method="patch"
                            class="grid gap-2"
                            v-slot="{ errors, processing }"
                        >
                            <Label for="cover" class="text-xs"
                                >PNG cover art</Label
                            >
                            <Input
                                id="cover"
                                name="cover"
                                type="file"
                                accept="image/png"
                                class="text-xs"
                            />
                            <InputError :message="errors.cover" />
                            <Button
                                type="submit"
                                size="sm"
                                variant="outline"
                                :disabled="processing"
                            >
                                {{ book.has_cover ? 'Replace' : 'Upload' }}
                            </Button>
                        </Form>

                        <Form
                            v-if="book.has_cover"
                            :action="base"
                            method="patch"
                            v-slot="{ processing }"
                        >
                            <input
                                type="hidden"
                                name="remove_cover"
                                value="1"
                            />
                            <Button
                                type="submit"
                                size="sm"
                                variant="ghost"
                                :disabled="processing"
                                >Remove cover</Button
                            >
                        </Form>
                    </div>
                </div>

                <div class="border-t pt-4">
                    <Form
                        :action="base"
                        method="patch"
                        class="grid gap-2"
                        v-slot="{ errors, processing }"
                    >
                        <Label for="book-title">Name</Label>
                        <Input
                            id="book-title"
                            name="title"
                            :default-value="book.title"
                        />
                        <InputError :message="errors.title" />
                        <Button
                            type="submit"
                            size="sm"
                            variant="outline"
                            :disabled="processing"
                            >Save</Button
                        >
                    </Form>

                    <p class="mt-3 text-xs text-muted-foreground">
                        The book id cannot change: every saved page on every
                        device keys off it.
                    </p>
                </div>

                <p class="border-t pt-4 text-xs text-muted-foreground">
                    <template v-if="book.last_published_at">
                        Last published v{{ book.latest_published_version }} on
                        {{ formatDateTime(book.last_published_at) }}.
                        <template v-if="book.modified_since_publish">
                            Edited since.
                        </template>
                    </template>
                    <template v-else>Never published.</template>
                </p>
            </div>

            <!-- ------------------------------------------------- pages --- -->
            <div class="rounded-lg border">
                <div
                    class="flex flex-wrap items-center justify-between gap-3 border-b p-4"
                >
                    <Heading
                        variant="small"
                        title="Pages"
                        description="Order is the order the child turns them in. The detail image is required; the masking image is optional."
                    />
                </div>

                <p
                    v-if="!book.pages || book.pages.length === 0"
                    class="p-4 text-sm text-muted-foreground"
                >
                    No pages yet.
                </p>

                <ul v-else class="divide-y">
                    <li
                        v-for="page in book.pages"
                        :key="page.ulid"
                        class="flex flex-wrap items-start gap-4 p-4"
                    >
                        <!-- Detail image: required, so always a picture. -->
                        <div class="grid w-32 gap-2">
                            <img
                                :src="page.display_url"
                                :alt="`Detail image for page ${page.page_index + 1}`"
                                :data-test="`page-${page.page_index}-display`"
                                class="size-32 rounded border object-contain"
                            />
                            <Form
                                :action="`${base}/pages/${page.page_index}`"
                                method="patch"
                                class="grid gap-1"
                                v-slot="{ processing }"
                            >
                                <Input
                                    name="display"
                                    type="file"
                                    accept="image/png"
                                    class="h-8 text-xs"
                                    :aria-label="`Replace the detail image of page ${page.page_index + 1}`"
                                />
                                <Button
                                    type="submit"
                                    size="sm"
                                    variant="outline"
                                    :disabled="processing"
                                    >Replace detail</Button
                                >
                            </Form>
                        </div>

                        <!-- Masking image: optional, so an empty slot when
                             there is none rather than a broken thumbnail. -->
                        <div class="grid w-32 gap-2">
                            <img
                                v-if="page.mask_url"
                                :src="page.mask_url"
                                :alt="`Masking image for page ${page.page_index + 1}`"
                                :data-test="`page-${page.page_index}-mask`"
                                class="size-32 rounded border bg-[repeating-conic-gradient(#e5e5e5_0%_25%,#ffffff_0%_50%)] bg-[length:12px_12px] object-contain"
                            />
                            <div
                                v-else
                                class="flex size-32 items-center justify-center rounded border border-dashed p-2 text-center text-xs text-muted-foreground"
                            >
                                No masking image
                            </div>

                            <Form
                                :action="`${base}/pages/${page.page_index}`"
                                method="patch"
                                class="grid gap-1"
                                v-slot="{ processing }"
                            >
                                <Input
                                    name="mask"
                                    type="file"
                                    accept="image/png"
                                    class="h-8 text-xs"
                                    :aria-label="`Replace the masking image of page ${page.page_index + 1}`"
                                />
                                <Button
                                    type="submit"
                                    size="sm"
                                    variant="outline"
                                    :disabled="processing"
                                >
                                    {{
                                        page.has_mask
                                            ? 'Replace mask'
                                            : 'Add mask'
                                    }}
                                </Button>
                            </Form>

                            <Form
                                v-if="page.has_mask"
                                :action="`${base}/pages/${page.page_index}`"
                                method="patch"
                                v-slot="{ processing }"
                            >
                                <input
                                    type="hidden"
                                    name="remove_mask"
                                    value="1"
                                />
                                <Button
                                    type="submit"
                                    size="sm"
                                    variant="ghost"
                                    :disabled="processing"
                                    >Remove mask</Button
                                >
                            </Form>
                        </div>

                        <div class="min-w-48 flex-1">
                            <p class="font-medium">
                                <Link
                                    :href="`${base}/pages/${page.page_index}`"
                                    class="underline-offset-4 hover:underline"
                                >
                                    {{ page.page_index + 1 }}.
                                    {{ pageLabel(page) }}
                                </Link>
                                <span
                                    class="ml-2 rounded-full px-2 py-0.5 text-xs"
                                    :class="statusClass[page.mapping_status]"
                                    >{{ page.mapping_status }}</span
                                >
                            </p>
                            <p class="text-sm text-muted-foreground">
                                {{ pageSummary(page) }}
                            </p>
                            <p
                                v-if="!page.publishable && page.blockers.length"
                                class="mt-1 text-sm text-destructive"
                            >
                                {{ page.blockers[0] }}
                            </p>
                        </div>

                        <div class="flex flex-col items-end gap-2">
                            <div class="flex items-center gap-2">
                                <Form
                                    v-if="page.page_index > 0"
                                    :action="`${base}/pages/${page.page_index}`"
                                    method="patch"
                                    v-slot="{ processing }"
                                >
                                    <input
                                        type="hidden"
                                        name="page_index"
                                        :value="page.page_index - 1"
                                    />
                                    <Button
                                        type="submit"
                                        size="sm"
                                        variant="outline"
                                        :disabled="processing"
                                        >Up</Button
                                    >
                                </Form>

                                <Form
                                    v-if="
                                        book.pages &&
                                        page.page_index < book.pages.length - 1
                                    "
                                    :action="`${base}/pages/${page.page_index}`"
                                    method="patch"
                                    v-slot="{ processing }"
                                >
                                    <input
                                        type="hidden"
                                        name="page_index"
                                        :value="page.page_index + 1"
                                    />
                                    <Button
                                        type="submit"
                                        size="sm"
                                        variant="outline"
                                        :disabled="processing"
                                        >Down</Button
                                    >
                                </Form>
                            </div>

                            <ConfirmDialog
                                :action="`${base}/pages/${page.page_index}`"
                                method="delete"
                                trigger-label="Delete page"
                                :data-test="`delete-page-${page.page_index}`"
                                confirm-label="Delete page"
                                :title="`Delete page ${page.page_index + 1}?`"
                                :description="`“${pageLabel(page)}” and its mapping are removed, and the pages after it move up. There is no undo.`"
                            />
                        </div>
                    </li>
                </ul>

                <div class="border-t p-4">
                    <Heading
                        variant="small"
                        title="Add page"
                        description="PNG only — the ID map generated from this art has to stay lossless. Adding a page queues its mapping straight away."
                    />

                    <Form
                        :action="`${base}/pages`"
                        method="post"
                        class="mt-4 grid gap-3 sm:grid-cols-[1fr_1fr_1fr_auto] sm:items-end"
                        v-slot="{ errors, processing }"
                    >
                        <div class="grid gap-2">
                            <Label for="display">Detail image</Label>
                            <Input
                                id="display"
                                name="display"
                                type="file"
                                accept="image/png"
                            />
                            <InputError :message="errors.display" />
                        </div>

                        <div class="grid gap-2">
                            <Label for="mask">Masking image (optional)</Label>
                            <Input
                                id="mask"
                                name="mask"
                                type="file"
                                accept="image/png"
                            />
                            <InputError :message="errors.mask" />
                        </div>

                        <div class="grid gap-2">
                            <Label for="title">Page name</Label>
                            <Input
                                id="title"
                                name="title"
                                placeholder="Coyote at dusk"
                            />
                            <InputError :message="errors.title" />
                        </div>

                        <Button type="submit" :disabled="processing"
                            >Add page</Button
                        >
                    </Form>
                </div>
            </div>
        </div>
    </div>
</template>
