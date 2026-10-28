import { useTranslation } from 'react-i18next'

export function useTezText() {
  const { i18n } = useTranslation()
  const chinese = (i18n.resolvedLanguage ?? i18n.language).startsWith('zh')
  return (zh: string, en: string) => (chinese ? zh : en)
}
