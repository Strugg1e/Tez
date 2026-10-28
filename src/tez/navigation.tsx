import {
  AltRouteOutlined,
  ArticleOutlined,
  MonitorHeartOutlined,
  RouteOutlined,
  SettingsOutlined,
} from '@mui/icons-material'
import { IconButton, Tooltip } from '@mui/material'
import { NavLink, useLocation } from 'react-router'

import { useTezText } from './use-text'

const routeSection = (path: string) => {
  if (['/proxies', '/rules'].includes(path)) return 'routes'
  if (path === '/profile') return 'profiles'
  if (['/connections', '/logs', '/unlock', '/diagnostics'].includes(path))
    return 'activity'
  if (path === '/settings') return 'settings'
  return 'connection'
}

export function TezNavigation() {
  const text = useTezText()
  const { pathname } = useLocation()
  const section = routeSection(pathname)
  const items = [
    {
      id: 'connection',
      to: '/',
      label: text('连接', 'Connection'),
      Icon: RouteOutlined,
    },
    {
      id: 'routes',
      to: '/proxies',
      label: text('线路', 'Routes'),
      Icon: AltRouteOutlined,
    },
    {
      id: 'profiles',
      to: '/profile',
      label: text('配置', 'Profiles'),
      Icon: ArticleOutlined,
    },
    {
      id: 'activity',
      to: '/connections',
      label: text('活动', 'Activity'),
      Icon: MonitorHeartOutlined,
    },
  ]
  const tabs =
    section === 'routes'
      ? [
          ['/proxies', text('节点与策略组', 'Nodes & policies')],
          ['/rules', text('分流规则', 'Rules')],
        ]
      : section === 'activity'
        ? [
            ['/connections', text('连接', 'Connections')],
            ['/logs', text('日志', 'Logs')],
            ['/diagnostics', text('网络检查', 'Network checks')],
            ['/unlock', text('服务可用性', 'Service availability')],
          ]
        : []

  return (
    <>
      <header className="tez-header" data-tauri-drag-region="true">
        <NavLink to="/" className="tez-brand" aria-label="Tez">
          <span className="tez-mark" aria-hidden="true">
            <i />
            <i />
            <i />
          </span>
          Tez
        </NavLink>
        <nav aria-label={text('主导航', 'Main navigation')}>
          {items.map(({ id, to, label, Icon }) => (
            <NavLink
              key={id}
              to={to}
              className={section === id ? 'active' : ''}
              aria-current={section === id ? 'page' : undefined}
            >
              <Icon fontSize="small" />
              <span>{label}</span>
            </NavLink>
          ))}
        </nav>
        <Tooltip title={text('设置', 'Settings')}>
          <IconButton
            component={NavLink}
            to="/settings"
            aria-label={text('设置', 'Settings')}
            className={section === 'settings' ? 'active' : ''}
          >
            <SettingsOutlined fontSize="small" />
          </IconButton>
        </Tooltip>
      </header>
      {tabs.length > 0 && (
        <nav
          className="tez-tabs"
          aria-label={text('页面导航', 'Page navigation')}
        >
          {tabs.map(([to, label]) => (
            <NavLink key={to} to={to}>
              {label}
            </NavLink>
          ))}
        </nav>
      )}
    </>
  )
}
