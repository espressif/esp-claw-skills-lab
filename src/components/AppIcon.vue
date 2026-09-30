<script setup lang="ts">
import { ref } from 'vue'

defineProps<{ src?: string }>()
const failedSrc = ref('')
</script>

<template>
  <!-- The adjacent title provides the accessible name. -->
  <img
    v-if="src && src !== failedSrc"
    class="app-icon"
    :src="src"
    alt=""
    width="48"
    height="48"
    decoding="async"
    @error="failedSrc = src"
  />
</template>

<style scoped>
.app-icon {
  width: 48px;
  height: 48px;
  flex-shrink: 0;
  border-radius: 10px;
  object-fit: contain;
}
</style>
