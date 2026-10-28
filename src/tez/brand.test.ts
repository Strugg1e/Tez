import { check } from '@tauri-apps/plugin-updater'
import { beforeEach, expect, it, vi } from 'vitest'

import { checkUpdateSafe } from '@/services/update'

vi.mock('@tauri-apps/plugin-updater', () => ({ check: vi.fn() }))

beforeEach(() => vi.clearAllMocks())

it('never uses upstream update infrastructure for Tez', async () => {
  await expect(checkUpdateSafe()).rejects.toThrow(
    'Tez client updates are not configured',
  )
  expect(check).not.toHaveBeenCalled()
})
