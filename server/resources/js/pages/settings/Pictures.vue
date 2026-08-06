<script setup lang="ts">
import { Form, Head } from '@inertiajs/vue3';
import PaintController from '@/actions/App/Http/Controllers/Settings/PaintController';
import Heading from '@/components/Heading.vue';
import { Button } from '@/components/ui/button';
import { edit } from '@/routes/pictures';

type OlderVersion = {
    ulid: string;
    painted_at: string;
    retained_at: string;
    expires_at: string;
    bytes: number;
};

type Page = {
    page_number: number;
    current_painted_at: string;
    older: OlderVersion[];
};

type Book = {
    book_uid: string;
    shelf: string | null;
    pages: Page[];
};

defineProps<{ books: Book[]; retentionDays: number }>();

defineOptions({
    layout: {
        breadcrumbs: [
            {
                title: 'Pictures',
                href: edit(),
            },
        ],
    },
});

const when = (iso: string) =>
    new Date(iso).toLocaleString(undefined, {
        dateStyle: 'medium',
        timeStyle: 'short',
    });
</script>

<template>
    <Head title="Pictures" />

    <h1 class="sr-only">Pictures</h1>

    <div class="space-y-6">
        <Heading
            variant="small"
            title="Pictures"
            :description="`When two devices colour the same page, one version wins. The other is kept here for ${retentionDays} days.`"
        />

        <div v-if="books.length === 0" class="text-sm text-muted-foreground">
            Nothing to restore. Every page is on its only version — which is how
            it usually stays.
        </div>

        <section
            v-for="book in books"
            :key="`${book.shelf ?? ''}-${book.book_uid}`"
            class="space-y-4"
        >
            <h2 class="text-sm font-medium">
                {{ book.book_uid }}
                <span class="text-muted-foreground">
                    · {{ book.shelf ?? 'Everyone' }}
                </span>
            </h2>

            <ul class="space-y-4">
                <li
                    v-for="page in book.pages"
                    :key="page.page_number"
                    class="rounded-lg border p-4"
                >
                    <p class="text-sm">
                        Page {{ page.page_number }} — showing the picture
                        coloured {{ when(page.current_painted_at) }}
                    </p>

                    <div
                        v-for="older in page.older"
                        :key="older.ulid"
                        class="mt-3 flex flex-wrap items-center gap-3"
                    >
                        <p class="flex-1 text-sm text-muted-foreground">
                            An older picture from
                            {{ when(older.painted_at) }} is kept until
                            {{ when(older.expires_at) }}.
                        </p>

                        <Form
                            v-bind="PaintController.restore.form(older.ulid)"
                            :options="{ preserveScroll: true }"
                            v-slot="{ processing }"
                        >
                            <Button
                                type="submit"
                                variant="secondary"
                                :disabled="processing"
                                :data-test="`restore-${older.ulid}`"
                            >
                                Restore the older picture
                            </Button>
                        </Form>
                    </div>
                </li>
            </ul>
        </section>
    </div>
</template>
