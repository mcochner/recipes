// Command reconcile-observer is a tiny, read-only Kubernetes controller used by
// the controllers-and-reconcile recipe.
//
// It watches ReplicaSets and Pods, but it never creates, updates, or deletes
// anything. Its only job is to LOG, so you can watch the reconcile loop work:
//
//   - "MAP pod -> RS"      a Pod event being translated into the key of its
//                          owning ReplicaSet (the "mapping" / event handler).
//   - "RECONCILE KEY"      the {namespace, name} key actually handed to
//                          Reconcile. It is ALWAYS a ReplicaSet key.
//   - "desired vs actual"  the level-triggered comparison, re-derived from
//                          current state on every call.
//
// Because it only reads, it is safe to run alongside the cluster's real
// kube-controller-manager: the real controller does the work (recreating pods),
// while this one narrates the keys.
package main

import (
	"context"
	"fmt"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

// observer reconciles ReplicaSets. It only reads + logs; it never writes.
type observer struct{ client client.Client }

func (o *observer) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	// We print compact, greppable lines (not the structured logger) so the
	// teaching output stays readable. The key is ALWAYS a ReplicaSet key.
	fmt.Printf("RECONCILE KEY      key=%s\n", req.NamespacedName)

	var rs appsv1.ReplicaSet
	if err := o.client.Get(ctx, req.NamespacedName, &rs); err != nil {
		fmt.Printf("    (ReplicaSet not found - likely deleted)   key=%s\n", req.NamespacedName)
		return reconcile.Result{}, client.IgnoreNotFound(err)
	}

	desired := int32(0)
	if rs.Spec.Replicas != nil {
		desired = *rs.Spec.Replicas
	}

	var pods corev1.PodList
	var selector map[string]string
	if rs.Spec.Selector != nil {
		selector = rs.Spec.Selector.MatchLabels
	}
	if err := o.client.List(ctx, &pods, client.InNamespace(rs.Namespace), client.MatchingLabels(selector)); err != nil {
		return reconcile.Result{}, err
	}
	fmt.Printf("    desired vs actual   key=%s desired=%d actual=%d\n", req.NamespacedName, desired, len(pods.Items))
	return reconcile.Result{}, nil
}

// mapPodToRS is the MAPPING: a Pod event -> the key of its owning ReplicaSet.
// This is the same idea as controller-runtime's Owns(&Pod{}), spelled out so we
// can print it.
func mapPodToRS(ctx context.Context, obj client.Object) []reconcile.Request {
	owner := metav1.GetControllerOf(obj) // reads metadata.ownerReferences (controller: true)
	if owner == nil || owner.Kind != "ReplicaSet" {
		return nil
	}
	key := types.NamespacedName{Namespace: obj.GetNamespace(), Name: owner.Name}
	fmt.Printf("MAP pod -> RS      pod=%s  enqueue=%s\n", obj.GetName(), key)
	return []reconcile.Request{{NamespacedName: key}}
}

func main() {
	ctrl.SetLogger(zap.New(zap.UseDevMode(true)))

	mgr, err := manager.New(ctrl.GetConfigOrDie(), manager.Options{
		// Don't bind the metrics port; we only care about logs.
		Metrics: metricsserver.Options{BindAddress: "0"},
	})
	if err != nil {
		panic(err)
	}

	if err := ctrl.NewControllerManagedBy(mgr).
		For(&appsv1.ReplicaSet{}).                                             // watch #1: ReplicaSets (identity mapping)
		Watches(&corev1.Pod{}, handler.EnqueueRequestsFromMapFunc(mapPodToRS)). // watch #2: Pods (mapped to owner RS)
		Complete(&observer{client: mgr.GetClient()}); err != nil {
		panic(err)
	}

	fmt.Println(">>> observer started - watching ReplicaSets + Pods (read-only). Ctrl-C to stop.")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		panic(err)
	}
}
