<script setup lang="ts">
import { Form, Head, Link } from '@inertiajs/vue3';
import { ref } from 'vue';
import Heading from '@/components/Heading.vue';
import InputError from '@/components/InputError.vue';
import { Button } from '@/components/ui/button';
import {
    Dialog,
    DialogClose,
    DialogContent,
    DialogDescription,
    DialogFooter,
    DialogHeader,
    DialogTitle,
    DialogTrigger,
} from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { formatDateTime } from '@/lib/datetime';
import type { AuthoredBook } from '@/types/admin';

/**
 * The colouring books, as a list you scan (BL-38).
 *
 * Four columns and nothing else, because those are the four things the artist
 * actually comes here to know: what it is called, how big it is, whether the
 * work in the browser has reached a player yet, and when it last did. Creating
 * a book is a button in the corner rather than a form sitting under the list —
 * it is done once per book and read many times.
 */
defineProps<{ books: AuthoredBook[] }>();

defineOptions({
    layout: {
        breadcrumbs: [{ title: 'Books', href: '/admin/books' }],
    },
});

const creating = ref(false);
</script>

<template>
    <Head title="Coloring books" />

    <div class="flex h-full flex-1 flex-col gap-6 p-4">
        <div class="flex flex-wrap items-start justify-between gap-3">
            <Heading
                title="Coloring books"
                description="Colouring books authored here. Each one publishes as its own pack, so the game sees exactly what it always did."
            />

            <Dialog v-model:open="creating">
                <DialogTrigger as-child>
                    <Button data-test="create-book">
                        Create new coloring book
                    </Button>
                </DialogTrigger>

                <DialogContent>
                    <Form
                        action="/admin/books"
                        method="post"
                        class="space-y-6"
                        v-slot="{ errors, processing }"
                    >
                        <DialogHeader class="space-y-3">
                            <DialogTitle>New coloring book</DialogTitle>
                            <DialogDescription>
                                The book id is permanent — every saved page on
                                every device keys off it, so it is never reused
                                and never renamed.
                            </DialogDescription>
                        </DialogHeader>

                        <div class="grid gap-2">
                            <Label for="book_uid">Book id</Label>
                            <Input
                                id="book_uid"
                                name="book_uid"
                                placeholder="coyote-2026"
                            />
                            <InputError :message="errors.book_uid" />
                        </div>

                        <div class="grid gap-2">
                            <Label for="title">Name</Label>
                            <Input
                                id="title"
                                name="title"
                                placeholder="Coyote"
                            />
                            <InputError :message="errors.title" />
                        </div>

                        <Label
                            class="flex items-center gap-2 text-sm font-normal"
                        >
                            <input
                                type="checkbox"
                                name="is_free"
                                value="1"
                                class="size-4"
                            />
                            Free pack
                        </Label>

                        <DialogFooter class="gap-2">
                            <DialogClose as-child>
                                <Button type="button" variant="secondary">
                                    Cancel
                                </Button>
                            </DialogClose>
                            <Button type="submit" :disabled="processing">
                                Create
                            </Button>
                        </DialogFooter>
                    </Form>
                </DialogContent>
            </Dialog>
        </div>

        <div
            v-if="books.length === 0"
            class="rounded-lg border p-8 text-center"
        >
            <p class="text-sm text-muted-foreground">
                No books yet. Create one, then add its pages.
            </p>
        </div>

        <div v-else class="overflow-hidden rounded-lg border">
            <div
                class="hidden grid-cols-[minmax(0,3fr)_6rem_minmax(0,1fr)_minmax(0,1.5fr)] gap-4 border-b bg-muted/40 px-4 py-2 text-xs font-medium tracking-wide text-muted-foreground uppercase sm:grid"
            >
                <span>Name</span>
                <span>Pages</span>
                <span>Status</span>
                <span>Last published</span>
            </div>

            <ul class="divide-y">
                <li v-for="book in books" :key="book.book_uid">
                    <!-- The whole row is the link: a list you open by clicking
                         a title is a list with a very small target in it. -->
                    <Link
                        :href="`/admin/books/${book.book_uid}`"
                        class="grid grid-cols-1 gap-1 px-4 py-3 transition-colors hover:bg-muted/50 sm:grid-cols-[minmax(0,3fr)_6rem_minmax(0,1fr)_minmax(0,1.5fr)] sm:items-center sm:gap-4"
                    >
                        <span class="flex items-center gap-3">
                            <img
                                v-if="book.cover_url"
                                :src="book.cover_url"
                                alt=""
                                class="size-10 rounded border object-contain"
                            />
                            <span
                                v-else
                                class="flex size-10 items-center justify-center rounded border border-dashed text-[10px] text-muted-foreground"
                                >no cover</span
                            >
                            <span class="min-w-0">
                                <span class="block truncate font-medium">{{
                                    book.title
                                }}</span>
                                <span
                                    class="block truncate text-xs text-muted-foreground"
                                >
                                    {{ book.book_uid
                                    }}<template v-if="book.is_free">
                                        · free</template
                                    >
                                </span>
                            </span>
                        </span>

                        <span class="text-sm text-muted-foreground">
                            {{ book.page_count }}
                            <span class="sm:hidden">page(s)</span>
                        </span>

                        <span class="flex flex-wrap items-center gap-2">
                            <span
                                v-if="book.latest_published_version === null"
                                class="rounded-full bg-muted px-2 py-0.5 text-xs text-muted-foreground"
                                >never published</span
                            >
                            <span
                                v-else-if="book.modified_since_publish"
                                class="rounded-full bg-amber-100 px-2 py-0.5 text-xs text-amber-900 dark:bg-amber-900/40 dark:text-amber-200"
                                >edited since publish</span
                            >
                            <span
                                v-else
                                class="rounded-full bg-emerald-100 px-2 py-0.5 text-xs text-emerald-900 dark:bg-emerald-900/40 dark:text-emerald-200"
                                >published</span
                            >
                            <span
                                v-if="book.unpublishable_page_count > 0"
                                class="rounded-full bg-destructive/15 px-2 py-0.5 text-xs text-destructive"
                            >
                                {{ book.unpublishable_page_count }} page(s) need
                                attention
                            </span>
                            <span
                                v-else-if="
                                    book.publishable &&
                                    book.latest_published_version === null
                                "
                                class="rounded-full bg-emerald-100 px-2 py-0.5 text-xs text-emerald-900 dark:bg-emerald-900/40 dark:text-emerald-200"
                                >ready to publish</span
                            >
                        </span>

                        <span class="text-sm text-muted-foreground">
                            <template v-if="book.last_published_at">
                                v{{ book.latest_published_version }} ·
                                {{ formatDateTime(book.last_published_at) }}
                            </template>
                            <template v-else>—</template>
                        </span>
                    </Link>
                </li>
            </ul>
        </div>
    </div>
</template>
