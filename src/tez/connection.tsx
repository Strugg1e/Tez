import {
  ArrowForwardRounded,
  ComputerOutlined,
  DnsOutlined,
  PublicOutlined,
  RouteOutlined,
  SettingsEthernetOutlined,
} from '@mui/icons-material'
import { Button, Collapse, Skeleton } from '@mui/material'
import { lazy, Suspense, useState } from 'react'
import { Link } from 'react-router'

import { BasePage } from '@/components/base'
import { ClashModeCard } from '@/components/home/clash-mode-card'
import { CurrentProxyCard } from '@/components/home/current-proxy-card'
import { EnhancedTrafficStats } from '@/components/home/enhanced-traffic-stats'
import { HomeProfileCard } from '@/components/home/home-profile-card'
import ProxyControlSwitches from '@/components/shared/proxy-control-switches'
import { useProfiles } from '@/hooks/use-profiles'
import { useSystemProxyState } from '@/hooks/use-system-proxy-state'
import { useSystemState } from '@/hooks/use-system-state'
import { useVerge } from '@/hooks/use-verge'
import {
  useClashConfigData,
  useProxiesData,
} from '@/providers/app-data-context'
import { showNotice } from '@/services/notice-service'

import TezMigration from './migration'
import { useTezText } from './use-text'

const IpInfoCard = lazy(() =>
  import('@/components/home/ip-info-card').then((module) => ({
    default: module.IpInfoCard,
  })),
)

export default function TezConnection() {
  const text = useTezText()
  const { verge } = useVerge()
  const { current, mutateProfiles } = useProfiles()
  const { runningMode, isLoading } = useSystemState()
  const { indicator } = useSystemProxyState()
  const { clashConfig } = useClashConfigData()
  const { proxyView } = useProxiesData()
  const [stage, setStage] = useState(1)
  const [trafficOpen, setTrafficOpen] = useState(false)
  const running = runningMode !== 'NotRunning' && !isLoading
  const mode = clashConfig?.mode?.toLowerCase()
  const group =
    mode === 'global' ? proxyView?.global : proxyView?.groups.find((g) => g.now)
  const route =
    mode === 'direct'
      ? text('直接连接', 'Direct')
      : (group?.now ?? text('未选择', 'Not selected'))
  const nodes = [
    {
      Icon: ComputerOutlined,
      title: text('本机', 'This Mac'),
      value: current?.name ?? text('未添加配置', 'No profile'),
    },
    {
      Icon: SettingsEthernetOutlined,
      title: text('网络接管', 'Network capture'),
      value: verge?.enable_tun_mode
        ? 'TUN'
        : indicator
          ? text('系统代理', 'System proxy')
          : text('未接管', 'Not captured'),
    },
    {
      Icon: RouteOutlined,
      title: text('分流策略', 'Routing policy'),
      value:
        mode === 'rule'
          ? text('规则分流', 'Rule')
          : mode === 'global'
            ? text('全局代理', 'Global')
            : mode === 'direct'
              ? text('直接连接', 'Direct')
              : '—',
    },
    {
      Icon: DnsOutlined,
      title: text('当前线路', 'Current route'),
      value: route,
    },
    {
      Icon: PublicOutlined,
      title: text('出口', 'Exit'),
      value: text('查看出口信息', 'Inspect exit'),
    },
  ]
  return (
    <BasePage
      title={text('连接', 'Connection')}
      header={
        <Button component={Link} to="/dashboard" size="small">
          {text('网络详情', 'Network details')}
        </Button>
      }
    >
      <div className="tez-connection">
        <TezMigration automatic />
        <div className="tez-connection-heading">
          <div>
            <span className={`tez-state ${running ? 'running' : ''}`}>
              {isLoading
                ? text('正在读取核心状态', 'Reading core state')
                : running
                  ? text('核心运行中', 'Core running')
                  : text('核心未运行', 'Core not running')}
            </span>
            <h1>{text('你的连接路径', 'Your connection path')}</h1>
          </div>
          <Button
            component={Link}
            to="/profile"
            variant="outlined"
            endIcon={<ArrowForwardRounded />}
          >
            {current ? current.name : text('添加配置', 'Add profile')}
          </Button>
        </div>
        <div
          className="tez-path"
          aria-label={text('连接路径', 'Connection path')}
        >
          {nodes.map(({ Icon, title, value }, index) => (
            <button
              key={title}
              onClick={() => setStage(index)}
              aria-pressed={stage === index}
              className={stage === index ? 'selected' : ''}
            >
              <Icon />
              <span>{title}</span>
              <strong title={value}>{value}</strong>
            </button>
          ))}
        </div>
        <section className="tez-path-detail" aria-label={nodes[stage].title}>
          {stage === 0 && (
            <HomeProfileCard
              current={current}
              onProfileUpdated={mutateProfiles}
            />
          )}
          {stage === 1 && (
            <>
              <h2>{text('网络接管', 'Network capture')}</h2>
              <ProxyControlSwitches onError={showNotice.error} />
            </>
          )}
          {stage === 2 && (
            <>
              <h2>{text('分流策略', 'Routing policy')}</h2>
              <ClashModeCard />
            </>
          )}
          {stage === 3 && <CurrentProxyCard />}
          {stage === 4 && (
            <Suspense
              fallback={<Skeleton variant="rectangular" height={200} />}
            >
              <IpInfoCard />
            </Suspense>
          )}
        </section>
        <div className="tez-traffic-heading">
          <h2>{text('实时流量', 'Live traffic')}</h2>
          <Button
            onClick={() => setTrafficOpen(!trafficOpen)}
            aria-expanded={trafficOpen}
          >
            {trafficOpen ? text('收起', 'Collapse') : text('展开', 'Expand')}
          </Button>
        </div>
        <Collapse in={trafficOpen} mountOnEnter>
          <EnhancedTrafficStats />
        </Collapse>
      </div>
    </BasePage>
  )
}
