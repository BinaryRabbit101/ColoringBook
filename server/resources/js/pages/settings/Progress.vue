<script setup lang="ts">
import { Form, Head } from '@inertiajs/vue3';
import { ref } from 'vue';
import ProgressController from '@/actions/App/Http/Controllers/Settings/ProgressController';
import Heading from '@/components/Heading.vue';
import { Button } from '@/components/ui/button';
import { edit } from '@/routes/progress';

type Book = {
    book_uid: string;
    pictures: number;
};

type Shelf = {
    key: string;
    name: string | null;
    books: Book[];
    pictures: number;
    erased_at: string | null;
};

defineProps<{ shelves: Shelf[] }>();

defineOptions({
    layout: {
        breadcrumbs: [
            {
                title: 'Progress',
                href: edit(),
            },
        ],
    },
});

// Which shelf is mid-"are you sure?". This deletes a child's colouring for
// good, on every device, so it never happens on a single click.
const confirming = ref<string | null>(null);

const when = (iso: string) =>
    new Date(iso).toLocaleString(undefined, {
        dateStyle: 'medium',
        timeStyle: 'short',
    });
</script>

<template>
    <Head title="Progress" />

    <h1 class="sr-only">Progress</h1>

    <div class="space-y-6">
        <Heading
            variant="small"
            title="Progress"
            description="What each shelf has coloured, and where to erase it. Erasing here reaches every device — the next time each one syncs, it clears itself too."
        />

        <section
            v-for="shelf in shelves"
            :key="shelf.key"
            class="space-y-3 rounded-lg border p-4"
        >
            <h2 class="text-sm font-medium">
                {{ shelf.name ?? 'Everyone' }}
            </h2>

            <p v-if="shelf.books.length === 0" class="text-sm text-muted-foreground">
                Nothing coloured yet.
            </p>

            <ul v-else class="space-y-1 text-sm text-muted-foreground">
                <li v-for="book in shelf.books" :key="book.book_uid">
                    {{ book.book_uid }} — {{ book.pictures }}
                    {{ book.pictures === 1 ? 'picture' : 'pictures' }}
                </li>
            </ul>

            <p v-if="shelf.erased_at" class="text-xs text-muted-foreground">
                Last erased {{ when(shelf.erased_at) }}.
            </p>

            <div class="flex flex-wrap items-center gap-3">
                <Button
                    v-if="confirming !== shelf.key"
                    variant="ghost"
                    class="text-red-600 dark:text-red-400"
                    :data-test="`erase-${shelf.key}`"
                    @click="confirming = shelf.key"
                >
                    Erase everything
                </Button>

                <template v-else>
                    <p class="flex-1 text-sm text-muted-foreground">
                        Erase every book and every picture on this shelf? This
                        cannot be undone, and it clears the shelf on every
                        device.
                    </p>
                    <Form
                        v-bind="ProgressController.destroy.form(shelf.key)"
                        :options="{ preserveScroll: true }"
                        v-slot="{ processing }"
                    >
                        <Button
                            type="submit"
                            variant="destructive"
                            :disabled="processing"
                            :data-test="`confirm-erase-${shelf.key}`"
                        >
                            Erase everything
                        </Button>
                    </Form>
                    <Button variant="ghost" @click="confirming = null">
                        Cancel
                    </Button>
                </template>
            </div>
        </section>
    </div>
</template>
