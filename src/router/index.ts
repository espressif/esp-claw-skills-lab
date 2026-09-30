import { createRouter, createWebHistory } from 'vue-router'
import i18n, { DEFAULT_LANG, SUPPORTED_LANGS, type Lang } from '@/i18n'

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes: [
    {
      path: '/',
      redirect: `/${DEFAULT_LANG}`,
    },
    {
      path: '/:lang',
      children: [
        {
          path: '',
          name: 'home',
          component: () => import('@/views/HomeView.vue'),
        },
        {
          path: ':kind(skill|app)/:id',
          name: 'detail',
          component: () => import('@/views/DetailView.vue'),
          props: true,
        },
      ],
    },
  ],
})

router.beforeEach((to) => {
  const lang = to.params.lang as string
  if (lang && SUPPORTED_LANGS.some((l) => l.id === lang)) {
    i18n.global.locale.value = lang as Lang
  }
})

export default router
