# Documentation defined in Library/Homebrew/cmd/setup-sandbox.rb

homebrew-setup-sandbox() {
  if [[ $(sysctl -n "kernel.unprivileged_userns_clone" || echo 0) != "1" ]]
  then
    sysctl -w kernel.unprivileged_userns_clone=1
  fi
  if [[ $(sysctl -n "user.max_user_namespaces" || echo 0) -lt 28633 ]]
  then
    sysctl -w user.max_user_namespaces=28633
  fi

  if [[ $(sysctl -n "kernel.apparmor_restrict_unprivileged_userns" || echo 0) != "0" ]]
  then
    sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 || true
  fi
}
