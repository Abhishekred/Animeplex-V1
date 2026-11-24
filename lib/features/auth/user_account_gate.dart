import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/admin/user_runtime_controls.dart';
import '../../core/di/injector.dart';
import '../../core/mode/content_mode.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/ui/source_switcher.dart';
import '../home/home_catalogue_prefs.dart';
import '../auth/auth_cubit.dart';
import '../../core/models/provider_info.dart' show ProviderType;

/// Keeps the user's app access aligned with authenticated server state.
/// Never asks for admin credentials: the authenticated user can SELECT only
/// their own status, and RLS/SECURITY DEFINER RPCs enforce source restrictions.
class UserAccountGate extends StatefulWidget {
  const UserAccountGate({super.key,required this.child});
  final Widget child;

  @override
  State<UserAccountGate> createState() => _UserAccountGateState();
}

class _UserAccountGateState extends State<UserAccountGate>
    with WidgetsBindingObserver {
  StreamSubscription<AuthState>? _authSub;
  Timer? _poll;
  bool _busy=false;
  bool _forcedUnavailable=false;
  String? _currentUid;
  // Prevent stale, repeatedly-polled server state from undoing a user's
  // manual selection and resetting Home's scroll position every 30 seconds.
  String? _lastSeenUnlockedRemoteProvider;
  bool _hasSeenUnlockedRemoteProvider = false;

  @override
  void initState(){
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final auth=sl<AuthCubit>();
    _currentUid=auth.state.user?.id;
    if(_currentUid != null) UserRuntimeControls.adoptUser(_currentUid!);
    _authSub=auth.stream.listen((state){
      final id=state.user?.id;
      if(id!=_currentUid){
        _currentUid=id;
        _forcedUnavailable=false;
        _hasSeenUnlockedRemoteProvider=false;
        _lastSeenUnlockedRemoteProvider=null;
        if(id==null) UserRuntimeControls.resetOnLogout();
        else UserRuntimeControls.adoptUser(id);
      }
      unawaited(_sync());
    });
    _poll=Timer.periodic(const Duration(seconds:30),(_)=>unawaited(_sync()));
    WidgetsBinding.instance.addPostFrameCallback((_){
      if(mounted)unawaited(_sync());
    });
    // Plugin installations from repositories may finish after the shell loads.
    unawaited(Future<void>.delayed(const Duration(seconds:8)).then((_){
      if(mounted)return _sync();
    }));
  }

  @override
  void dispose(){
    _poll?.cancel();
    _authSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state){
    if(state==AppLifecycleState.resumed)unawaited(_sync());
  }

  Future<void> _sync() async {
    if(_busy || !mounted || _currentUid==null)return;
    _busy=true;
    try{
      final row=await UserRuntimeControls.refresh();
      if(!mounted || _currentUid!=row?.userId)return;
      if(row!.isBanned){
        if(_forcedUnavailable)setState(()=>_forcedUnavailable=false);
        return;
      }
      final buckets=categorizedSources();
      final sources=<({String id,String name})>[];
      for(final item in [
        ...buckets.anime,...buckets.movies,...buckets.nsfw,
        ...buckets.manga,...buckets.novel,
      ]){
        sources.add((id:item.id,name:item.label));
      }
      final available=sources.map((x)=>x.id).toSet();
      final target=row.providerLocked
          ? row.forcedProviderId : row.currentProviderId;
      // An unlocked user's server value is a last-reported selection, not a
      // perpetual forced setting. Apply it only when it changes on the server
      // (e.g. the admin chose a new provider), rather than on every poll.
      // A lock is different: it must be enforced whenever the app syncs.
      final remoteChanged = !_hasSeenUnlockedRemoteProvider ||
          _lastSeenUnlockedRemoteProvider != row.currentProviderId;
      _lastSeenUnlockedRemoteProvider=row.currentProviderId;
      _hasSeenUnlockedRemoteProvider=true;
      final shouldApplyTarget = row.providerLocked || remoteChanged;
      if(row.providerLocked && target!=null && !available.contains(target)){
        if(!_forcedUnavailable)setState(()=>_forcedUnavailable=true);
      }else{
        if(_forcedUnavailable)setState(()=>_forcedUnavailable=false);
        if(shouldApplyTarget && target!=null && available.contains(target)){
          final active=sl<ActiveSourceCubit>();
          if(active.state!=target)active.setSourceFromAdmin(target);
          final provider=sourceTypeOf(target);
          final mode=switch(provider){
            ProviderType.manga=>ContentMode.manga,
            ProviderType.novel=>ContentMode.novel,
            _=>ContentMode.anime,
          };
          if(HomeCataloguePrefs.sourceIdFor(mode)!=target){
            await HomeCataloguePrefs.setSourceIdFor(mode,target);
          }
        }
      }
      await UserRuntimeControls.reportAvailable(
        currentSourceId:sl<ActiveSourceCubit>().state,
        sources:sources,
      );
    }catch(error){
      debugPrint('[account-gate] Provider report deferred: $error');
    }finally{_busy=false;}
  }

  @override
  Widget build(BuildContext context){
    return ValueListenableBuilder<UserRuntimeSnapshot>(
      valueListenable:UserRuntimeControls.state,
      builder:(context,snapshot,child){
        if(_currentUid!=null && snapshot.userId==_currentUid &&
            snapshot.isBanned){
          return _AccountBlockScreen(
            title:'Account banned',
            icon:Icons.block_rounded,
            message:(snapshot.banReason?.trim().isNotEmpty??false)
                ? snapshot.banReason!.trim()
                : 'This account has been suspended. Contact the administrator for details.',
            secondary:'This ban is linked to your account. Signing in again will not remove it.',
            onRetry:()=>unawaited(_sync()),
          );
        }
        if(_currentUid!=null && snapshot.userId==_currentUid &&
            snapshot.providerLocked && _forcedUnavailable){
          return _AccountBlockScreen(
            title:'Provider locked',
            icon:Icons.lock_outline_rounded,
            message:'Your administrator selected ${snapshot.forcedProviderId ?? 'a provider'}. It is not installed on this device yet.',
            secondary:'Ask the administrator to install it or unlock provider switching.',
            onRetry:()=>unawaited(_sync()),
          );
        }
        return child!;
      },
      child:widget.child,
    );
  }
}

class _AccountBlockScreen extends StatelessWidget {
  const _AccountBlockScreen({
    required this.title,required this.icon,required this.message,
    required this.secondary,required this.onRetry,
  });
  final String title,message,secondary;
  final IconData icon;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context){
    return PopScope(canPop:false,child:Scaffold(
      backgroundColor:AppColors.bg,
      body:SafeArea(child:Center(child:ConstrainedBox(
        constraints:const BoxConstraints(maxWidth:460),
        child:Padding(
          padding:const EdgeInsets.all(28),
          child:Column(mainAxisSize:MainAxisSize.min,children:[
            Icon(icon,size:58,color:AppColors.accent),
            const SizedBox(height:20),
            Text(title,style:const TextStyle(color:Colors.white,
              fontSize:27,fontWeight:FontWeight.w700),textAlign:TextAlign.center),
            const SizedBox(height:12),
            SelectableText(message,style:const TextStyle(color:Colors.white,
              fontSize:16,height:1.5),textAlign:TextAlign.center),
            const SizedBox(height:12),
            Text(secondary,style:const TextStyle(color:Colors.white60,
              fontSize:13,height:1.4),textAlign:TextAlign.center),
            const SizedBox(height:22),
            FilledButton.icon(onPressed:onRetry,
              icon:const Icon(Icons.refresh_rounded),
              label:const Text('Check status')),
          ]),
        ),
      ))),
    ));
  }
}
