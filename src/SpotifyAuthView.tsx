import { requireNativeViewManager } from "expo-modules-core";
import * as React from "react";
import { ViewProps } from "react-native";

import { SpotifyAuthViewProps } from "./SpotifyAuth.types";

const NativeView: React.ComponentType<SpotifyAuthViewProps & ViewProps> =
  requireNativeViewManager("SpotifyAuth");

export default function SpotifyAuthView(
  props: SpotifyAuthViewProps,
): JSX.Element {
  return <NativeView {...props} />;
}
