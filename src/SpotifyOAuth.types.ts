export type OnLoadEventPayload = {
  url: string;
};

export type SpotifyOAuthModuleEvents = {
  onChange: (params: ChangeEventPayload) => void;
};

export type ChangeEventPayload = {
  value: string;
};
