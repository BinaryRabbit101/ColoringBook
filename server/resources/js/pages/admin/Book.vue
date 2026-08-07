<script setup lang="ts">
import { Form, Head, Link } from '@inertiajs/vue3';
import Heading from '@/components/Heading.vue';
import InputError from '@/components/InputError.vue';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import type { AuthoredBook, AuthoredPage } from '@/types/admin';

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

    return `${size} · ${regions} region(s)${page.has_mask ? ' · masked' : ''}`;
}
</script>

<template>
    <Head :title="book.title" />

    <div class="flex h-full flex-1 flex-col gap-6 p-4">
        <Heading
            :title="book.title"
            :description="`${book.book_uid} · pack ${book.pack_slug} (${book.pack_status})${book.is_free ? ' · free' : ''}`"
        />

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

        <div class="rounded-lg border">
            <div
                class="flex flex-wrap items-center justify-between gap-3 border-b p-4"
            >
                <Heading
                    variant="small"
                    title="Pages"
                    description="Order is the order the child turns them in. The detail image is required; the masking image is optional."
                />

                <div class="flex items-center gap-2">
                    <Button variant="outline" as-child>
                        <Link :href="`/admin/packs/${book.pack_slug}`"
                            >Pack</Link
                        >
                    </Button>

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
                            {{ processing ? 'Publishing…' : 'Publish' }}
                        </Button>
                    </Form>
                </div>
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
                    class="flex flex-wrap items-center justify-between gap-3 p-4"
                >
                    <div class="flex items-center gap-3">
                        <img
                            v-if="page.preview_url"
                            :src="page.preview_url"
                            :alt="`Region overlay for page ${page.page_index + 1}`"
                            class="size-16 rounded border object-contain"
                        />
                        <div>
                            <p class="font-medium">
                                <Link
                                    :href="`${base}/pages/${page.page_index}`"
                                    class="underline-offset-4 hover:underline"
                                >
                                    {{ page.page_index + 1 }}.
                                    {{ page.title ?? page.file_stem }}
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
                                class="text-sm text-destructive"
                            >
                                {{ page.blockers[0] }}
                            </p>
                        </div>
                    </div>

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
                                variant="outline"
                                :disabled="processing"
                                >Down</Button
                            >
                        </Form>

                        <Form
                            :action="`${base}/pages/${page.page_index}`"
                            method="delete"
                            v-slot="{ processing }"
                        >
                            <Button
                                type="submit"
                                variant="outline"
                                :disabled="processing"
                                >Remove</Button
                            >
                        </Form>
                    </div>
                </li>
            </ul>
        </div>

        <div class="rounded-lg border p-4">
            <Heading
                variant="small"
                title="Add a page"
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
                    <Label for="title">Page title</Label>
                    <Input
                        id="title"
                        name="title"
                        placeholder="Coyote at dusk"
                    />
                    <InputError :message="errors.title" />
                </div>

                <Button type="submit" :disabled="processing">Add page</Button>
            </Form>
        </div>

        <div class="rounded-lg border p-4">
            <Heading
                variant="small"
                title="Book details"
                description="The book id cannot change: every saved page on every device keys off it."
            />

            <Form
                :action="base"
                method="patch"
                class="mt-4 grid gap-3 sm:grid-cols-[1fr_auto] sm:items-end"
                v-slot="{ errors, processing }"
            >
                <div class="grid gap-2">
                    <Label for="book-title">Title</Label>
                    <Input
                        id="book-title"
                        name="title"
                        :default-value="book.title"
                    />
                    <InputError :message="errors.title" />
                </div>

                <Button type="submit" variant="outline" :disabled="processing"
                    >Save</Button
                >
            </Form>

            <Form
                :action="base"
                method="delete"
                class="mt-6 flex items-center justify-between gap-3 rounded-lg border border-destructive/50 p-4"
                v-slot="{ processing }"
            >
                <p class="text-sm text-muted-foreground">
                    <template v-if="book.latest_published_version">
                        This book has been published, so removing it
                        <strong>retires</strong> its pack — households that own
                        it keep it.
                    </template>
                    <template v-else>
                        This book has never been published, so removing it
                        deletes it outright.
                    </template>
                </p>
                <Button
                    type="submit"
                    variant="destructive"
                    :disabled="processing"
                    >Remove book</Button
                >
            </Form>
        </div>
    </div>
</template>
