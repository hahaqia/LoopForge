import React from "react";
import "./home-logo.css";
import logoMark from "./assets/logo-mark.png";

// The brand mark is shipped as artwork rather than retraced stroke paths, so the
// glyph renders exactly as designed. The container keeps the intro tempo.
export default function HomeLogo() {
  return (
    <div className="home-logo" aria-hidden="true">
      <img
        className="home-logo-glyph"
        src={logoMark}
        alt=""
        width="64"
        height="64"
        draggable="false"
      />
    </div>
  );
}
