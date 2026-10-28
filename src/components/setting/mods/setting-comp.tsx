import { ChevronRightRounded } from '@mui/icons-material'
import {
  Box,
  List,
  ListItem,
  ListItemButton,
  ListItemText,
  ListSubheader,
} from '@mui/material'
import CircularProgress from '@mui/material/CircularProgress'
import React, { ReactNode, use, useState } from 'react'

import { TezSettingsSearchContext } from '@/tez/settings-search'
import isAsyncFunction from '@/utils/is-async-function'

interface ItemProps {
  label: ReactNode
  extra?: ReactNode
  children?: ReactNode
  secondary?: ReactNode
  onClick?: () => void | Promise<any>
}

export const SettingItem: React.FC<ItemProps> = ({
  label,
  extra,
  children,
  secondary,
  onClick,
}) => {
  const clickable = !!onClick

  const primary = (
    <Box sx={{ display: 'flex', alignItems: 'center', fontSize: '14px' }}>
      <span>{label}</span>
      {extra ? extra : null}
    </Box>
  )

  const [isLoading, setIsLoading] = useState(false)
  const search = use(TezSettingsSearchContext)
  const handleClick = () => {
    if (onClick) {
      if (isAsyncFunction(onClick)) {
        setIsLoading(true)
        onClick()!.finally(() => setIsLoading(false))
      } else {
        onClick()
      }
    }
  }

  if (
    search &&
    typeof label === 'string' &&
    !label.toLocaleLowerCase().includes(search)
  )
    return null

  return clickable ? (
    <ListItem disablePadding>
      <ListItemButton onClick={handleClick} disabled={isLoading}>
        <ListItemText primary={primary} secondary={secondary} />
        {isLoading ? (
          <CircularProgress color="inherit" size={20} />
        ) : (
          <ChevronRightRounded />
        )}
      </ListItemButton>
    </ListItem>
  ) : (
    <ListItem sx={{ pt: '5px', pb: '5px' }}>
      <ListItemText primary={primary} secondary={secondary} />
      {children}
    </ListItem>
  )
}

export const SettingList: React.FC<{
  title: string
  children: ReactNode
}> = ({ title, children }) => (
  <List>
    <ListSubheader
      sx={[
        { background: 'transparent', fontSize: '16px', fontWeight: '700' },
        ({ palette }) => {
          return {
            color: palette.text.primary,
          }
        },
      ]}
      disableSticky
    >
      {title}
    </ListSubheader>

    {children}
  </List>
)
