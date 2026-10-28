import {
  CheckCircleOutlineRounded,
  CloseRounded,
  ManageSearchRounded,
  RefreshRounded,
  UndoRounded,
} from '@mui/icons-material'
import {
  Alert,
  Box,
  Button,
  Checkbox,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  FormControlLabel,
  IconButton,
  Radio,
  RadioGroup,
  Stack,
  Typography,
} from '@mui/material'
import { useState } from 'react'
import { useNavigate } from 'react-router'

import { useProfiles } from '@/hooks/use-profiles'
import {
  migrateLocalProfiles,
  rollbackProfileMigration,
  scanMigrationSources,
  type MigrationResult,
} from '@/services/cmds'
import { mutate } from '@/services/mutate'
import { errorDetail } from '@/services/notice-service'
import { useQuery } from '@/services/query-client'

import { useTezText } from './use-text'

export default function TezMigration({
  automatic = false,
}: {
  automatic?: boolean
}) {
  const text = useTezText()
  const navigate = useNavigate()
  const { profiles } = useProfiles()
  const empty =
    profiles !== undefined &&
    !profiles.items?.some(
      (item) => item.type === 'remote' || item.type === 'local',
    )
  const [open, setOpen] = useState(false)
  const [selection, setSelection] = useState('')
  const [scriptsConfirmed, setScriptsConfirmed] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [result, setResult] = useState<MigrationResult | null>(null)
  const [undoConfirm, setUndoConfirm] = useState(false)
  const scan = useQuery({
    queryKey: ['scanMigrationSources'],
    queryFn: scanMigrationSources,
    enabled: open || (automatic && empty),
    staleTime: 300_000,
    retry: false,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
  })
  const sources = scan.data?.sources ?? []
  const selected =
    sources.find((source) => source.id === selection) ??
    sources.find((source) => source.fingerprint)
  const ready =
    empty &&
    selected?.fingerprint &&
    !scan.data?.destinationHasProfiles &&
    (!selected.scriptCount || scriptsConfirmed)
  const close = () => {
    if (!busy) {
      setOpen(false)
      setUndoConfirm(false)
    }
  }
  const refresh = async () => {
    setError('')
    setScriptsConfirmed(false)
    setResult(null)
    try {
      await scan.refetch()
    } catch (err) {
      setError(errorDetail(err))
    }
  }
  const migrate = async () => {
    if (!ready || !selected?.fingerprint || busy) return
    setBusy(true)
    setError('')
    try {
      await mutate(
        () =>
          migrateLocalProfiles(
            selected.id,
            selected.fingerprint!,
            scriptsConfirmed,
          ),
        {
          id: 'migrate-local-profiles',
          errorNotice: false,
          onFulfilled: setResult,
          revalidate: [['getProfiles'], ['scanMigrationSources']],
        },
      )
    } catch (err) {
      setError(errorDetail(err))
    } finally {
      setBusy(false)
    }
  }
  const rollback = async () => {
    if (busy) return
    setBusy(true)
    setError('')
    try {
      await mutate(rollbackProfileMigration, {
        id: 'migrate-local-profiles',
        errorNotice: false,
        onFulfilled: () => {
          setResult(null)
          setUndoConfirm(false)
          setScriptsConfirmed(false)
        },
        revalidate: [['getProfiles'], ['scanMigrationSources']],
      })
    } catch (err) {
      setError(errorDetail(err))
    } finally {
      setBusy(false)
    }
  }
  const trigger = (
    <Button
      size="small"
      variant="outlined"
      startIcon={<ManageSearchRounded />}
      onClick={() => {
        setResult(null)
        setError('')
        setScriptsConfirmed(false)
        setOpen(true)
      }}
    >
      {text('扫描本机配置', 'Find local profiles')}
    </Button>
  )
  return (
    <>
      {automatic
        ? empty &&
          sources.some((source) => source.fingerprint) && (
            <div className="tez-migration-discovery">
              <div>
                <strong>
                  {text('发现本机已有配置', 'Local profiles found')}
                </strong>
                <span>
                  {sources
                    .filter((source) => source.fingerprint)
                    .map(
                      (source) =>
                        `${source.label} · ${source.profileCount} ${text('份配置', 'profiles')}`,
                    )
                    .join(' / ')}
                </span>
              </div>
              {trigger}
            </div>
          )
        : trigger}
      <Dialog
        open={open}
        onClose={close}
        maxWidth="sm"
        fullWidth
        sx={{ '& .MuiButton-root': { textTransform: 'none' } }}
      >
        <DialogTitle
          sx={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            gap: 2,
          }}
        >
          {text('本机配置迁移', 'Local profile migration')}
          <IconButton
            aria-label={text('关闭', 'Close')}
            disabled={busy}
            onClick={close}
          >
            <CloseRounded />
          </IconButton>
        </DialogTitle>
        <DialogContent dividers>
          {error && (
            <Alert severity="error" sx={{ mb: 2 }}>
              {error}
            </Alert>
          )}
          {undoConfirm ? (
            <Alert severity="warning">
              {text(
                '恢复迁移前的 Tez 配置清单。原客户端、迁移备份和复制的文件均保留。',
                'Restore the previous Tez profile index. The original client, backups and copied files are retained.',
              )}
            </Alert>
          ) : result ? (
            <Stack spacing={2}>
              <CheckCircleOutlineRounded color="success" />
              <Typography>
                {text(
                  `已复制 ${result.profileCount} 份配置、${result.fileCount} 个文件。`,
                  `Copied ${result.profileCount} profiles and ${result.fileCount} files.`,
                )}
              </Typography>
              <Alert severity="info">
                {text(
                  '尚未启用配置，自动更新暂停。请在配置页面确认后再启用。',
                  'No profile was activated. Automatic updates are paused. Review your profiles before activating one.',
                )}
              </Alert>
            </Stack>
          ) : (
            <>
              <Stack
                direction="row"
                sx={{
                  mb: 2,
                  alignItems: 'center',
                  justifyContent: 'space-between',
                  gap: 2,
                }}
              >
                <Typography variant="body2" color="text.secondary">
                  {text(
                    '仅复制配置。原数据、系统代理、TUN 与服务状态不变。',
                    'Copies profiles only. Original data, system proxy, TUN and service state are unchanged.',
                  )}
                </Typography>
                <IconButton
                  aria-label={text('重新扫描', 'Scan again')}
                  disabled={busy || scan.isFetching}
                  onClick={() => void refresh()}
                >
                  <RefreshRounded />
                </IconButton>
              </Stack>
              {scan.isFetching && (
                <Box
                  role="status"
                  sx={{ display: 'flex', alignItems: 'center', gap: 1, py: 2 }}
                >
                  <CircularProgress size={18} />
                  {text('正在扫描本机配置…', 'Scanning local profiles…')}
                </Box>
              )}
              {scan.error && (
                <Alert severity="error">{errorDetail(scan.error)}</Alert>
              )}
              {!scan.isFetching && !scan.error && sources.length === 0 && (
                <Typography sx={{ py: 3 }}>
                  {text(
                    '未发现已知客户端的配置目录。',
                    'No known client configuration directories were found.',
                  )}
                </Typography>
              )}
              {scan.data?.destinationHasProfiles && (
                <Alert severity="info" sx={{ mb: 2 }}>
                  {text(
                    'Tez 已有配置。自动迁移不会覆盖现有数据。',
                    'Tez already has profiles. Automatic migration will not overwrite existing data.',
                  )}
                </Alert>
              )}
              <RadioGroup
                aria-label={text('迁移来源', 'Migration source')}
                value={selected?.id ?? ''}
                onChange={(e) => {
                  setSelection(e.target.value)
                  setScriptsConfirmed(false)
                }}
              >
                {sources.map((source) => (
                  <Box
                    key={source.id}
                    sx={{
                      borderBottom: 1,
                      borderColor: 'divider',
                      py: 1.5,
                      minWidth: 0,
                    }}
                  >
                    <FormControlLabel
                      value={source.id}
                      disabled={
                        busy ||
                        !source.fingerprint ||
                        !!scan.data?.destinationHasProfiles
                      }
                      control={<Radio />}
                      sx={{ alignItems: 'flex-start', m: 0, width: '100%' }}
                      label={
                        <Box sx={{ minWidth: 0, pt: 0.8 }}>
                          <Typography variant="body2" sx={{ fontWeight: 600 }}>
                            {source.label}
                          </Typography>
                          <Typography
                            variant="caption"
                            color="text.secondary"
                            component="div"
                            sx={{ overflowWrap: 'anywhere' }}
                          >
                            {source.path}
                          </Typography>
                          <Typography variant="caption">
                            {text(
                              `${source.profileCount} 份配置 · ${source.fileCount} 个文件 · ${source.scriptCount} 个增强脚本`,
                              `${source.profileCount} profiles · ${source.fileCount} files · ${source.scriptCount} scripts`,
                            )}
                          </Typography>
                          {source.error && (
                            <Typography
                              variant="caption"
                              color="error"
                              component="div"
                            >
                              {source.error}
                            </Typography>
                          )}
                        </Box>
                      }
                    />
                  </Box>
                ))}
              </RadioGroup>
              {!!selected?.scriptCount &&
                !scan.data?.destinationHasProfiles && (
                  <FormControlLabel
                    sx={{ mt: 2 }}
                    control={
                      <Checkbox
                        checked={scriptsConfirmed}
                        disabled={busy}
                        onChange={(e) => setScriptsConfirmed(e.target.checked)}
                      />
                    }
                    label={
                      <Typography variant="body2">
                        {text(
                          '保留增强脚本。我了解：迁移时不执行，但后续启用配置或启动客户端时可能执行。',
                          'Keep enhancement scripts. They are not executed during migration, but may run when profiles are activated or the client starts later.',
                        )}
                      </Typography>
                    }
                  />
                )}
            </>
          )}
          {!undoConfirm &&
            (result || scan.data?.lastMigration?.canRollback) && (
              <Button
                startIcon={<UndoRounded />}
                color="inherit"
                sx={{ mt: 2 }}
                disabled={busy}
                onClick={() => {
                  setError('')
                  setUndoConfirm(true)
                }}
              >
                {text('撤销此次迁移', 'Undo this migration')}
              </Button>
            )}
        </DialogContent>
        <DialogActions sx={{ px: 3, py: 2 }}>
          {undoConfirm ? (
            <>
              <Button disabled={busy} onClick={() => setUndoConfirm(false)}>
                {text('取消', 'Cancel')}
              </Button>
              <Button
                color="warning"
                variant="contained"
                disabled={busy}
                onClick={() => void rollback()}
              >
                {text('确认撤销', 'Confirm undo')}
              </Button>
            </>
          ) : result ? (
            <>
              <Button onClick={close}>{text('完成', 'Done')}</Button>
              <Button
                variant="contained"
                onClick={() => {
                  close()
                  navigate('/profile')
                }}
              >
                {text('查看配置', 'Review profiles')}
              </Button>
            </>
          ) : (
            <>
              <Button disabled={busy} onClick={close}>
                {text('稍后', 'Later')}
              </Button>
              <Button
                variant="contained"
                disabled={!ready || busy || scan.isFetching}
                onClick={() => void migrate()}
                startIcon={
                  busy ? (
                    <CircularProgress size={16} color="inherit" />
                  ) : undefined
                }
              >
                {busy
                  ? text('正在复制…', 'Copying…')
                  : text('复制到 Tez', 'Copy to Tez')}
              </Button>
            </>
          )}
        </DialogActions>
      </Dialog>
    </>
  )
}
