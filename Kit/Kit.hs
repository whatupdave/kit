module Kit.Kit where
  import Kit.Util
    
  data Kit = Kit {
    kitName :: String,
    kitVersion :: String
  } deriving (Eq, Show, Ord, Read)

  kitFileName :: Kit -> String
  kitFileName k = kitName k ++ "-" ++ kitVersion k

  kitConfigFile :: Kit -> String
  kitConfigFile kit = kitFileName kit </> (kitName kit ++ ".xcconfig")
