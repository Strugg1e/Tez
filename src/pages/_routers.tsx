import { createBrowserRouter, RouteObject } from 'react-router'

import TezConnection from '@/tez/connection'
import TezDiagnostics from '@/tez/diagnostics'
import TezSettings from '@/tez/settings'

import Layout from './_layout'
import { navItems } from './_navigation'
import HomePage from './home'

export const router = createBrowserRouter([
  {
    path: '/',
    Component: Layout,
    children: [
      ...navItems.map(
        (item) =>
          ({
            path: item.path,
            Component:
              item.path === '/'
                ? TezConnection
                : item.path === '/settings'
                  ? TezSettings
                  : item.Component,
          }) as RouteObject,
      ),
      { path: '/dashboard', Component: HomePage },
      { path: '/diagnostics', Component: TezDiagnostics },
    ],
  },
])
