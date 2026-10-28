import { SearchRounded } from '@mui/icons-material'
import { InputAdornment, TextField } from '@mui/material'
import { useMemo, useState } from 'react'

import { BasePage } from '@/components/base'
import SettingClash from '@/components/setting/setting-clash'
import SettingSystem from '@/components/setting/setting-system'
import SettingVergeAdvanced from '@/components/setting/setting-verge-advanced'
import SettingVergeBasic from '@/components/setting/setting-verge-basic'
import { showNotice } from '@/services/notice-service'
import { version } from '@root/package.json'

import { TezSettingsSearchContext } from './settings-search'
import { useTezText } from './use-text'

export default function TezSettings() {
  const text = useTezText()
  const [category, setCategory] = useState('general')
  const [search, setSearch] = useState('')
  const normalizedSearch = useMemo(
    () => search.trim().toLocaleLowerCase(),
    [search],
  )
  const categories = [
    {
      id: 'general',
      label: text('通用与外观', 'General & appearance'),
      Component: SettingVergeBasic,
    },
    {
      id: 'network',
      label: text('网络接管', 'Network capture'),
      Component: SettingSystem,
    },
    {
      id: 'core',
      label: text('核心与连接', 'Core & connections'),
      Component: SettingClash,
    },
    {
      id: 'advanced',
      label: text('备份与高级设置', 'Backup & advanced'),
      Component: SettingVergeAdvanced,
    },
  ]
  return (
    <BasePage title={text('设置', 'Settings')}>
      <div className="tez-settings">
        <aside>
          <TextField
            size="small"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder={text('搜索设置', 'Search settings')}
            slotProps={{
              htmlInput: { 'aria-label': text('搜索设置', 'Search settings') },
              input: {
                startAdornment: (
                  <InputAdornment position="start">
                    <SearchRounded fontSize="small" />
                  </InputAdornment>
                ),
              },
            }}
          />
          <nav aria-label={text('设置分类', 'Settings categories')}>
            {categories.map(({ id, label }) => (
              <button
                key={id}
                className={category === id && !search ? 'selected' : ''}
                onClick={() => {
                  setCategory(id)
                  setSearch('')
                }}
              >
                {label}
              </button>
            ))}
            <button
              className={category === 'about' && !search ? 'selected' : ''}
              onClick={() => {
                setCategory('about')
                setSearch('')
              }}
            >
              {text('关于与许可', 'About & licenses')}
            </button>
          </nav>
          <div className="tez-settings-version">
            Tez <span>{version}</span>
          </div>
        </aside>
        <div className="tez-settings-content">
          <TezSettingsSearchContext value={normalizedSearch}>
            {categories
              .filter((c) => search || c.id === category)
              .map(({ id, Component }) => (
                <section key={id}>
                  <Component onError={showNotice.error} />
                </section>
              ))}
          </TezSettingsSearchContext>
          {category === 'about' && !search && (
            <section className="tez-about">
              <span className="tez-wordmark">Tez</span>
              <p>
                {text(
                  '独立的桌面网络客户端',
                  'An independent desktop network client',
                )}
              </p>
              <dl>
                <dt>{text('版本', 'Version')}</dt>
                <dd>{version}</dd>
                <dt>{text('许可证', 'License')}</dt>
                <dd>GPL-3.0-only</dd>
              </dl>
              <h2>{text('开源致谢', 'Open-source acknowledgments')}</h2>
              <p>
                {text(
                  'Tez 基于 Clash Verge Rev 的开源代码开发。保留原作者版权和 GPL 许可。代理核心使用 Mihomo。',
                  'Tez is derived from Clash Verge Rev. Original copyright and GPL terms are retained. Powered by Mihomo.',
                )}
              </p>
              <a
                href="https://github.com/clash-verge-rev/clash-verge-rev"
                target="_blank"
                rel="noreferrer"
              >
                {text('上游源码与贡献者', 'Upstream source & contributors')}
              </a>
              <p>
                {text(
                  'Tez 尚未配置独立更新服务器；本版本不会使用上游客户端更新。',
                  'Tez has no configured update server. This build does not install upstream client updates.',
                )}
              </p>
            </section>
          )}
        </div>
      </div>
    </BasePage>
  )
}
