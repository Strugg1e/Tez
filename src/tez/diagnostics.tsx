import { Skeleton } from '@mui/material'
import { lazy, Suspense } from 'react'

import { BasePage } from '@/components/base'

import { useTezText } from './use-text'

const ClashInfoCard = lazy(() =>
  import('@/components/home/clash-info-card').then((module) => ({
    default: module.ClashInfoCard,
  })),
)
const SystemInfoCard = lazy(() =>
  import('@/components/home/system-info-card').then((module) => ({
    default: module.SystemInfoCard,
  })),
)
const TestCard = lazy(() =>
  import('@/components/home/test-card').then((module) => ({
    default: module.TestCard,
  })),
)

export default function TezDiagnostics() {
  const text = useTezText()
  return (
    <BasePage title={text('网络检查', 'Network checks')}>
      <div className="tez-diagnostics">
        <Suspense fallback={<Skeleton variant="rectangular" height={200} />}>
          <TestCard />
          <ClashInfoCard />
          <SystemInfoCard />
        </Suspense>
      </div>
    </BasePage>
  )
}
