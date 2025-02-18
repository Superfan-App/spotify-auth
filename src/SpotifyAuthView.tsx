// src/SpotifyAuthView.tsx

import { requireNativeViewManager } from "expo-modules-core";
import * as React from "react";
import { ViewProps } from "react-native";

import { SpotifyAuthViewProps } from "./SpotifyAuth.types";

const NativeView: React.ComponentType<SpotifyAuthViewProps & ViewProps> =
  requireNativeViewManager("SpotifyAuth");

export default function SpotifyAuthView(
  props: SpotifyAuthViewProps,
): JSX.Element {
  console.log('Registering SpotifyAuthView with props:', JSON.stringify(props));
  return <NativeView {...props} />;
}
