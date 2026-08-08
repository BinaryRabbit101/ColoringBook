<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import type { StickerAnim } from '@/types/admin';

/**
 * An animated sticker, playing (BL-38).
 *
 * The sheet is the element's background, scaled so that exactly one cell fills
 * the box, and the frame is chosen by moving `background-position`. A JS timer
 * rather than a CSS `steps()` animation, for one reason that matters: `frames`
 * can be **fewer** than `hframes * vframes` — a 7-frame animation on a 4x2
 * sheet is legal and normal — and a two-axis `steps()` pair always walks the
 * whole grid, so the operator would watch a blank cell flash by that the game
 * will never show. Counting frames in a timer plays exactly what ships.
 *
 * Percentage `background-position` is the awkward part of the CSS box model
 * here: 0% is the left edge and 100% the RIGHT edge, so the step between cells
 * is `100 / (cols - 1)`, not `100 / cols` — and a single-column sheet has no
 * step at all, which is why the divisor is guarded rather than clamped.
 */
const props = withDefaults(
    defineProps<{
        src: string;
        anim: StickerAnim;
        /** Box size in pixels; one frame is drawn to fill it. */
        size?: number;
        /** Paused previews are useful in a dense list. */
        playing?: boolean;
    }>(),
    { size: 64, playing: true },
);

const frame = ref(0);
let timer: ReturnType<typeof setInterval> | null = null;

const total = computed(() =>
    Math.max(
        1,
        Math.min(props.anim.frames, props.anim.hframes * props.anim.vframes),
    ),
);

const style = computed(() => {
    const cols = Math.max(1, props.anim.hframes);
    const rows = Math.max(1, props.anim.vframes);
    const index = frame.value % total.value;
    const col = index % cols;
    const row = Math.floor(index / cols);

    return {
        width: `${props.size}px`,
        height: `${props.size}px`,
        backgroundImage: `url("${props.src}")`,
        backgroundSize: `${cols * 100}% ${rows * 100}%`,
        backgroundPosition: `${cols > 1 ? (col / (cols - 1)) * 100 : 0}% ${
            rows > 1 ? (row / (rows - 1)) * 100 : 0
        }%`,
        // Sprite sheets are pixel grids; smoothing them blurs the cell edges
        // into their neighbours, which is the one artefact this preview exists
        // to let the operator see.
        imageRendering: 'pixelated' as const,
    };
});

function stop(): void {
    if (timer !== null) {
        clearInterval(timer);
        timer = null;
    }
}

function start(): void {
    stop();

    if (!props.playing) {
        return;
    }

    const fps = Math.min(30, Math.max(1, props.anim.fps));

    timer = setInterval(() => {
        frame.value = (frame.value + 1) % total.value;
    }, 1000 / fps);
}

watch(
    () => [props.src, props.anim, props.playing],
    () => {
        frame.value = 0;
        start();
    },
    { immediate: true, deep: true },
);

onBeforeUnmount(stop);
</script>

<template>
    <!-- Checkerboard on the wrapper, sheet on the child: they are both
         backgrounds, and one element cannot carry the two. -->
    <span
        class="inline-block rounded border bg-[repeating-conic-gradient(#e5e5e5_0%_25%,#ffffff_0%_50%)] bg-[length:12px_12px]"
        :title="`${anim.frames} frames at ${anim.fps} fps`"
    >
        <span class="block" :style="style" />
    </span>
</template>
