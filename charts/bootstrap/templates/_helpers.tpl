{{/*
Owner label rendered from the Pulumi-managed EnvironmentConfig. Child charts use
this to label their workloads so they satisfy the require-owner-label Kyverno
policy. Falls back to the legacy bootstrap-scoped value when needed.
*/}}
{{- define "bootstrap.ownerLabels" -}}
{{- $owner := .Values.environmentConfig.owner | default .Values.environmentConfig.bootstrap.owner -}}
{{- if $owner }}
owner: {{ $owner | quote }}
{{- end }}
{{- end }}

{{/*
Validate that required values are not empty
*/}}
{{- define "bootstrap.validateRequiredValues" -}}
{{- $requiredValues := list
  (dict "path" "environmentConfig.bootstrap.resourcePrefix" "value" .Values.environmentConfig.bootstrap.resourcePrefix)
  (dict "path" "environmentConfig.bootstrap.awsAccountId" "value" .Values.environmentConfig.bootstrap.awsAccountId)
  (dict "path" "environmentConfig.bootstrap.awsPartition" "value" .Values.environmentConfig.bootstrap.awsPartition)
  (dict "path" "environmentConfig.bootstrap.awsRegion" "value" .Values.environmentConfig.bootstrap.awsRegion)
  (dict "path" "environmentConfig.bootstrap.clusterName" "value" .Values.environmentConfig.bootstrap.clusterName)
  (dict "path" "environmentConfig.bootstrap.clusterFqdn" "value" .Values.environmentConfig.bootstrap.clusterFqdn)
  (dict "path" "environmentConfig.bootstrap.clusterHost" "value" .Values.environmentConfig.bootstrap.clusterHost)
  (dict "path" "environmentConfig.bootstrap.clusterEndpoint" "value" .Values.environmentConfig.bootstrap.clusterEndpoint)
  (dict "path" "environmentConfig.bootstrap.oidcProvider" "value" .Values.environmentConfig.bootstrap.oidcProvider)
  (dict "path" "environmentConfig.bootstrap.oidcProviderArn" "value" .Values.environmentConfig.bootstrap.oidcProviderArn)
  (dict "path" "environmentConfig.bootstrap.awsVpcId" "value" .Values.environmentConfig.bootstrap.awsVpcId)
  (dict "path" "environmentConfig.bootstrap.awsLbcRoleArn" "value" .Values.environmentConfig.bootstrap.awsLbcRoleArn)
  (dict "path" "environmentConfig.bootstrap.awsEbsCsiDriverRoleArn" "value" .Values.environmentConfig.bootstrap.awsEbsCsiDriverRoleArn)
  (dict "path" "environmentConfig.bootstrap.awsExternalDnsRoleArn" "value" .Values.environmentConfig.bootstrap.awsExternalDnsRoleArn)
  (dict "path" "environmentConfig.bootstrap.certManagerRoleArn" "value" .Values.environmentConfig.bootstrap.certManagerRoleArn)
  (dict "path" "environmentConfig.bootstrap.karpenterRoleArn" "value" .Values.environmentConfig.bootstrap.karpenterRoleArn)
  (dict "path" "environmentConfig.bootstrap.crossplaneProviderAwsIamRoleArn" "value" .Values.environmentConfig.bootstrap.crossplaneProviderAwsIamRoleArn)
  (dict "path" "environmentConfig.bootstrap.karpenterInstanceProfile" "value" .Values.environmentConfig.bootstrap.karpenterInstanceProfile)
-}}
{{- range $requiredValues -}}
  {{- if not .value -}}
    {{- fail (printf "Value '%s' is required but not set in values.yaml" .path) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate HSP AWS Platform required values when enabled
*/}}
{{- define "bootstrap.validateHspAwsPlatformValues" -}}
{{- if .Values.features.hspAwsPlatform.enabled -}}
{{- $requiredValues := list
  (dict "path" "environmentConfig.sharedServicesAccountId" "value" .Values.environmentConfig.sharedServicesAccountId)
  (dict "path" "environmentConfig.bootstrap.awsPrivateSubnetIds" "value" .Values.environmentConfig.bootstrap.awsPrivateSubnetIds)
  (dict "path" "environmentConfig.bootstrap.awsRdsSubnetGroup" "value" .Values.environmentConfig.bootstrap.awsRdsSubnetGroup)
  (dict "path" "environmentConfig.bootstrap.awsRedshiftSubnetGroup" "value" .Values.environmentConfig.bootstrap.awsRedshiftSubnetGroup)
  (dict "path" "environmentConfig.bootstrap.awsElasticacheSubnetGroup" "value" .Values.environmentConfig.bootstrap.awsElasticacheSubnetGroup)
  (dict "path" "environmentConfig.bootstrap.awsRdsSecurityGroups" "value" .Values.environmentConfig.bootstrap.awsRdsSecurityGroups)
  (dict "path" "environmentConfig.bootstrap.awsRedshiftSecurityGroups" "value" .Values.environmentConfig.bootstrap.awsRedshiftSecurityGroups)
  (dict "path" "environmentConfig.bootstrap.awsElasticacheSecurityGroups" "value" .Values.environmentConfig.bootstrap.awsElasticacheSecurityGroups)
  (dict "path" "environmentConfig.bootstrap.awsActivemqSecurityGroups" "value" .Values.environmentConfig.bootstrap.awsActivemqSecurityGroups)
-}}
{{- range $requiredValues -}}
  {{- if not .value -}}
    {{- fail (printf "Value '%s' is required when features.hspAwsPlatform.enabled is true" .path) -}}
  {{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate K3S values for Karpenter EC2NodeClass
*/}}
{{/*
The Amazon Linux release (nodeOs) and SELinux mode of the Karpenter workers, from k3s-on-ec2's
nodeOs and selinuxMode. Defaults: al2023 and permissive, what clusters ran before either existed.
bootSELinuxMode is the mode that release's AMI boots in; the user data switches only from that.
*/}}
{{- define "bootstrap.nodeOs" -}}
{{- .Values.environmentConfig.bootstrap.nodeOs | default "al2023" -}}
{{- end -}}
{{- define "bootstrap.selinuxMode" -}}
{{- .Values.environmentConfig.bootstrap.selinuxMode | default "permissive" -}}
{{- end -}}
{{- define "bootstrap.bootSELinuxMode" -}}
{{- ternary "enforcing" "permissive" (eq (include "bootstrap.nodeOs" .) "al2027") -}}
{{- end -}}

{{/*
Who issues the cluster's public certificates, from k3s-on-ec2's certificateIssuer: letsencrypt
(default, also when unset) or acm, AWS Certificate Manager through the cluster's ACME endpoint.
publicIssuer is the ClusterIssuer the Certificates reference.
*/}}
{{- define "bootstrap.certificateIssuer" -}}
{{- .Values.environmentConfig.bootstrap.certificateIssuer | default "letsencrypt" -}}
{{- end -}}
{{- define "bootstrap.publicIssuer" -}}
{{- ternary "acm" "letsencrypt-prod" (eq (include "bootstrap.certificateIssuer" .) "acm") -}}
{{- end -}}
{{- define "bootstrap.validateCertificateValues" -}}
{{- $issuer := include "bootstrap.certificateIssuer" . -}}
{{- if not (has $issuer (list "letsencrypt" "acm")) -}}
  {{- fail (printf "environmentConfig.bootstrap.certificateIssuer must be letsencrypt or acm, got %q" $issuer) -}}
{{- end -}}
{{- if eq $issuer "acm" -}}
  {{- range $k := list "acmeDirectoryUrl" "acmeEabKeyId" -}}
    {{- if not (get $.Values.environmentConfig.bootstrap $k) -}}
      {{- fail (printf "environmentConfig.bootstrap.%s is required with certificateIssuer=acm" $k) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{- define "bootstrap.validateK3sValues" -}}
{{- $requiredValues := list
  (dict "path" "environmentConfig.bootstrap.k3sTokenParameterName" "value" .Values.environmentConfig.bootstrap.k3sTokenParameterName)
  (dict "path" "environmentConfig.bootstrap.k3sVersionParameterName" "value" .Values.environmentConfig.bootstrap.k3sVersionParameterName)
-}}
{{- range $requiredValues -}}
  {{- if not .value -}}
    {{- fail (printf "Value '%s' is required for K3S node provisioning" .path) -}}
  {{- end -}}
{{- end -}}
{{- if not (has (include "bootstrap.nodeOs" .) (list "al2023" "al2027")) -}}
  {{- fail (printf "environmentConfig.bootstrap.nodeOs must be al2023 or al2027, got %q" (include "bootstrap.nodeOs" .)) -}}
{{- end -}}
{{- if not (has (include "bootstrap.selinuxMode" .) (list "permissive" "enforcing")) -}}
  {{- fail (printf "environmentConfig.bootstrap.selinuxMode must be permissive or enforcing, got %q" (include "bootstrap.selinuxMode" .)) -}}
{{- end -}}
{{- end -}}
