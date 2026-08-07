<script setup lang="ts">
import { Form, Head, Link } from '@inertiajs/vue3';
import Heading from '@/components/Heading.vue';
import InputError from '@/components/InputError.vue';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import type { AuthoredBook } from '@/types/admin';

defineProps<{ books: AuthoredBook[] }>();

defineOptions({
    layout: {
        breadcrumbs: [{ title: 'Books', href: '/admin/books' }],
    },
});
</script>

<template>
    <Head title="Books" />

    <div class="flex h-full flex-1 flex-col gap-6 p-4">
        <Heading
            title="Books"
            description="Colouring books authored here. Each one publishes as its own pack, so the game sees exactly what it always did."
        />

        <div v-if="books.length === 0" class="text-sm text-muted-foreground">
            No books yet. Create one below, then add its pages.
        </div>

        <ul v-else class="grid gap-3">
            <li
                v-for="book in books"
                :key="book.book_uid"
                class="rounded-lg border p-4"
            >
                <div class="flex flex-wrap items-center justify-between gap-3">
                    <div>
                        <Link
                            :href="`/admin/books/${book.book_uid}`"
                            class="font-medium underline-offset-4 hover:underline"
                        >
                            {{ book.title }}
                        </Link>
                        <p class="text-sm text-muted-foreground">
                            {{ book.book_uid }} · {{ book.page_count }} page(s)
                            ·
                            <template v-if="book.latest_published_version">
                                published v{{ book.latest_published_version }}
                            </template>
                            <template v-else>never published</template>
                        </p>
                    </div>

                    <div class="flex items-center gap-2">
                        <span
                            v-if="book.is_free"
                            class="rounded-full bg-sky-100 px-2 py-0.5 text-xs text-sky-900 dark:bg-sky-900/40 dark:text-sky-200"
                            >free</span
                        >
                        <span
                            v-if="book.unpublishable_page_count > 0"
                            class="rounded-full bg-amber-100 px-2 py-0.5 text-xs text-amber-900 dark:bg-amber-900/40 dark:text-amber-200"
                        >
                            {{ book.unpublishable_page_count }} page(s) need
                            attention
                        </span>
                        <span
                            v-else-if="book.publishable"
                            class="rounded-full bg-emerald-100 px-2 py-0.5 text-xs text-emerald-900 dark:bg-emerald-900/40 dark:text-emerald-200"
                            >ready to publish</span
                        >
                    </div>
                </div>
            </li>
        </ul>

        <div class="rounded-lg border p-4">
            <Heading
                variant="small"
                title="New book"
                description="The book id is permanent — every saved page on every device keys off it, so it is never reused and never renamed."
            />

            <Form
                action="/admin/books"
                method="post"
                class="mt-4 grid gap-3 sm:grid-cols-[1fr_1fr_auto] sm:items-end"
                v-slot="{ errors, processing }"
            >
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
                    <Label for="title">Title</Label>
                    <Input id="title" name="title" placeholder="Coyote" />
                    <InputError :message="errors.title" />
                </div>

                <div class="grid gap-2">
                    <Label class="flex items-center gap-2 text-sm font-normal">
                        <input
                            type="checkbox"
                            name="is_free"
                            value="1"
                            class="size-4"
                        />
                        Free pack
                    </Label>
                    <Button type="submit" :disabled="processing">Create</Button>
                </div>
            </Form>
        </div>
    </div>
</template>
