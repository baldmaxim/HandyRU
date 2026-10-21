import React from "react";

const APP_NAME = "HandyRU";

const AppTextLogo = ({
  width,
  className,
}: {
  width?: number;
  className?: string;
}) => {
  // Size the text so the wordmark roughly fills `width` (about 0.6em/char).
  const fontSize = width ? Math.round(width / (APP_NAME.length * 0.6)) : 24;
  return (
    <span
      className={`font-semibold text-text whitespace-nowrap text-center ${className ?? ""}`}
      style={{ fontSize }}
    >
      {APP_NAME}
    </span>
  );
};

export default AppTextLogo;
