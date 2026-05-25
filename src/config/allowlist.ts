export const ALLOWED_CATEGORIES = [
  'game',
  'utility',
  'hardware',
  'media',
  'network',
  'sensor',
  'ai',
] as const

export type Category = (typeof ALLOWED_CATEGORIES)[number]

export const ALLOWED_PERIPHERALS = [
  'camera',
  'led',
  'motor',
  'speaker',
  'microphone',
  'display',
  'button',
  'gpio',
  'battery',
  'ir',
  'servo',
  'ws2812',
] as const

export type Peripheral = (typeof ALLOWED_PERIPHERALS)[number]

export const FEATURED_SKILLS: string[] = [
  'bilibili_up_fans',
  'camera_preview',
  'china_a_share_quote',
  'clock_dial_demo',
  'current_ip_info',
  'current_weather',
  'flappy_bird',
  'github_repo_star',
  'lcd_touch_paint',
]
