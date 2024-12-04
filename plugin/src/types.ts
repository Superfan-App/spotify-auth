export type SpotifyScopes =
  | 'app-remote-control'
  | 'playlist-modify-private'
  | 'playlist-modify-public'
  | 'playlist-read-collaborative'
  | 'playlist-read-private'
  | 'streaming'
  | 'user-follow-modify'
  | 'user-follow-read'
  | 'user-library-modify'
  | 'user-library-read'
  | 'user-modify-playback-state'
  | 'user-read-currently-playing'
  | 'user-read-email'
  | 'user-read-playback-position'
  | 'user-read-playback-state'
  | 'user-read-private'
  | 'user-read-recently-played'
  | 'user-top-read'

export interface SpotifyConfig {
  clientID: string
  tokenRefreshURL: string
  tokenSwapURL: string
  scheme: string
  callback: string
  scopes: SpotifyScopes[]
}