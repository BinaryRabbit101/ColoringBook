<script setup lang="ts">
import { Form } from '@inertiajs/vue3';
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

/**
 * A destructive action behind a modal: the trigger opens a dialog, the dialog
 * submits the form.
 *
 * Every delete on the authoring screens goes through this. Those screens are
 * dense grids of small buttons — a page row, a sticker card — and a bare
 * `<Form method="delete">` there is one mis-aimed click away from taking a
 * book's worth of work with it, with no undo anywhere in the system.
 *
 * The form lives INSIDE the dialog rather than being submitted from outside it:
 * `processing` then belongs to the button the operator actually pressed, and a
 * slow delete disables the confirm rather than the trigger they have already
 * moved away from.
 */
withDefaults(
    defineProps<{
        /** Where the confirmed action posts. */
        action: string;
        method?: 'delete' | 'post' | 'patch';
        title: string;
        description?: string;
        /** The label on the button inside the dialog. */
        confirmLabel?: string;
        /** The label on the trigger, when no `#trigger` slot is given. */
        triggerLabel?: string;
        triggerVariant?: 'default' | 'destructive' | 'outline' | 'ghost';
        triggerSize?: 'default' | 'sm' | 'lg';
        confirmVariant?: 'default' | 'destructive';
        /** Hooks for Dusk, on the trigger and the confirm respectively. */
        dataTest?: string;
        confirmDataTest?: string;
        disabled?: boolean;
    }>(),
    {
        method: 'delete',
        confirmLabel: 'Delete',
        triggerLabel: 'Delete',
        triggerVariant: 'outline',
        triggerSize: 'sm',
        confirmVariant: 'destructive',
        disabled: false,
    },
);
</script>

<template>
    <Dialog>
        <DialogTrigger as-child>
            <slot name="trigger">
                <Button
                    type="button"
                    :variant="triggerVariant"
                    :size="triggerSize"
                    :disabled="disabled"
                    :data-test="dataTest"
                >
                    {{ triggerLabel }}
                </Button>
            </slot>
        </DialogTrigger>

        <DialogContent>
            <Form
                :action="action"
                :method="method"
                class="space-y-6"
                v-slot="{ processing }"
            >
                <DialogHeader class="space-y-3">
                    <DialogTitle>{{ title }}</DialogTitle>
                    <DialogDescription v-if="description">
                        {{ description }}
                    </DialogDescription>
                </DialogHeader>

                <slot />

                <DialogFooter class="gap-2">
                    <DialogClose as-child>
                        <Button type="button" variant="secondary">
                            Cancel
                        </Button>
                    </DialogClose>

                    <Button
                        type="submit"
                        :variant="confirmVariant"
                        :disabled="processing"
                        :data-test="confirmDataTest"
                    >
                        {{ confirmLabel }}
                    </Button>
                </DialogFooter>
            </Form>
        </DialogContent>
    </Dialog>
</template>
